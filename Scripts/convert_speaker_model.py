#!/usr/bin/env python3
"""
Builds SpeakerEmbedder.mlpackage: a single Core ML model that takes RAW 16 kHz
mono Float32 waveform and returns a speaker embedding, with the log-mel
filterbank front end traced INTO the graph so Swift never touches feature
extraction (PLAN-SPEAKER-VERIFICATION.md, Phase 1).

Two sources, same interface contract:

  --source wespeaker   (default; the bundled model) WeSpeaker ResNet34-LM
                       trained on VoxCeleb, from the ONNX build published in
                       k2-fsa/sherpa-onnx's GitHub releases. Front end: Kaldi
                       fbank (80 mel, 25/10 ms, hamming, pre-emphasis, int16
                       scale, no dither) + per-utterance mean normalisation,
                       exactly as wespeaker's CLI computes it. 256-dim output.
  --source speechbrain The plan's first choice, SpeechBrain ECAPA-TDNN
                       (speechbrain/spkrec-ecapa-voxceleb, 192-dim). Needs
                       huggingface.co reachable. Its Fbank uses torch.stft,
                       whose coremltools conversion is broken on torch >= 2.6
                       (apple/coremltools#2504) — hence the torch pin; if it
                       still fails the STFT is swapped for a conv1d DFT.

    python3 -m pip install "torch<=2.5" coremltools onnx onnx2torch onnxruntime torchaudio [speechbrain]
    python3 Scripts/convert_speaker_model.py --out Sources/LookMomNoHands/Resources/SpeakerEmbedder.mlpackage

Input : "waveform"  Float32 [1, T], T in 8000…160000 samples (0.5–10 s @ 16 kHz), -1…1
Output: "embedding" Float32 [1, D] (NOT unit-normalised; Swift normalises)

The model's `version` field carries MODEL_VERSION; SpeakerVerifier.modelVersion
in Swift must match it — enrolled voiceprints are invalidated when it changes.
"""

import argparse
import math
import os
import shutil
import sys
import time
import urllib.request

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SAMPLE_RATE = 16000
MIN_SAMPLES = 8000                       # 0.5 s
MAX_SAMPLES = 160000                     # 10 s
DEFAULT_SAMPLES = 40000                  # 2.5 s — the wake-word grab

WESPEAKER_FILE = "wespeaker_en_voxceleb_resnet34_LM.onnx"
WESPEAKER_URL = ("https://github.com/k2-fsa/sherpa-onnx/releases/download/"
                 "speaker-recongition-models/" + WESPEAKER_FILE)      # (sic) tag typo is upstream's
WESPEAKER_VERSION = "wespeaker-resnet34-lm-v1"

SPEECHBRAIN_SOURCE = "speechbrain/spkrec-ecapa-voxceleb"
SPEECHBRAIN_VERSION = "ecapa-voxceleb-v1"


def cosine(a, b):
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


# ---------------------------------------------------------------------------
# WeSpeaker route
# ---------------------------------------------------------------------------

class KaldiFbank(nn.Module):
    """torchaudio.compliance.kaldi.fbank(dither=0, hamming, 80 mel) as ONE conv1d:
    framing, DC removal, pre-emphasis, windowing and the (zero-padded 512-pt)
    DFT are all linear in the frame, so they compose into a single
    [2*257, 400] kernel applied with stride 160 (snip_edges=True). Then power
    spectrum → mel matrix → log → per-utterance mean subtraction (wespeaker's
    CMN). Verified against torchaudio to ~1e-4 in check_wespeaker()."""

    def __init__(self, n_mels=80, sr=SAMPLE_RATE, frame=400, hop=160, n_fft=512, preemph=0.97):
        super().__init__()
        import torchaudio.compliance.kaldi as kaldi
        self.hop = hop
        n_bins = n_fft // 2 + 1
        dc = torch.eye(frame) - torch.full((frame, frame), 1.0 / frame)
        pre = torch.eye(frame)
        for i in range(1, frame):
            pre[i, i - 1] = -preemph
        pre[0, 0] = 1.0 - preemph                       # kaldi replicates x[0] for x[-1]
        window = torch.diag(torch.hamming_window(frame, periodic=False, alpha=0.54, beta=0.46))
        n = torch.arange(frame, dtype=torch.float64)
        k = torch.arange(n_bins, dtype=torch.float64)
        angle = 2.0 * math.pi * torch.outer(k, n) / n_fft
        dft = torch.cat([torch.cos(angle), -torch.sin(angle)], dim=0).float()   # [2*bins, frame]
        kernel = dft @ window @ pre @ dc
        self.register_buffer("kernel", kernel.unsqueeze(1))                      # [2*bins, 1, frame]
        mel = kaldi.get_mel_banks(n_mels, n_fft, float(sr), 20.0, 0.0, 100.0, -500.0, 1.0)[0]
        mel = F.pad(mel, (0, 1))                                                 # [n_mels, bins]
        self.register_buffer("mel", mel.t().contiguous())                        # [bins, n_mels]
        self.n_bins = n_bins

    def forward(self, wav):                                  # [1, T], -1…1
        x = (wav * 32768.0).unsqueeze(1)                     # kaldi works at int16 scale
        y = F.conv1d(x, self.kernel, stride=self.hop)        # [1, 2*bins, frames]
        power = y[:, : self.n_bins, :] ** 2 + y[:, self.n_bins :, :] ** 2
        power = power.transpose(1, 2)                        # [1, frames, bins]
        mel = torch.matmul(power, self.mel)                  # [1, frames, n_mels]
        feats = torch.log(torch.clamp(mel, min=1.1920928955078125e-07))
        return feats - feats.mean(dim=1, keepdim=True)       # CMN


class WeSpeakerEmbedder(nn.Module):
    """Fbank → ResNet34 trunk (from ONNX via onnx2torch) → TSTP pooling →
    linear. The ONNX pooling computes the unbiased variance with a ReduceProd
    over a Shape, which coremltools can't convert, so the graph is cut before
    pooling and the tail is re-expressed with plain tensor ops."""

    def __init__(self, onnx_path):
        super().__init__()
        import onnx
        from onnx import numpy_helper
        from onnx2torch import convert

        model = onnx.load(onnx_path)
        inits = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}
        consts = {}
        for node in model.graph.node:
            if node.op_type == "Constant":
                consts[node.output[0]] = numpy_helper.to_array(node.attribute[0].t)
        # Find the trunk output: the tensor the pooling's ReduceMean/Shape read.
        prod = next(n for n in model.graph.node if n.op_type == "ReduceProd")
        gather = next(n for n in model.graph.node if n.output[0] == prod.input[0])
        shape = next(n for n in model.graph.node if n.output[0] == gather.input[0])
        trunk_out = shape.input[0]
        eps_add = next(n for n in model.graph.node if n.op_type == "Sqrt")
        add = next(n for n in model.graph.node if n.output[0] == eps_add.input[0])
        self.eps = float(consts[add.input[1]].ravel()[0])
        gemm = next(n for n in model.graph.node if n.op_type == "Gemm")
        weight = torch.from_numpy(inits[gemm.input[1]].copy())
        bias = torch.from_numpy(inits[gemm.input[2]].copy())
        self.linear = nn.Linear(weight.shape[1], weight.shape[0])
        with torch.no_grad():
            self.linear.weight.copy_(weight)
            self.linear.bias.copy_(bias)
        self.register_buffer("mean_vec", torch.from_numpy(inits["mean_vec"].copy()))
        self.output_dim = int(weight.shape[0])

        trunk_path = onnx_path + ".trunk.onnx"
        onnx.utils.extract_model(onnx_path, trunk_path, ["feats"], [trunk_out])
        self.trunk = convert(onnx.load(trunk_path)).eval()
        self.fbank = KaldiFbank()
        self.eval()

    def forward(self, wav):                                  # [1, T]
        feats = self.fbank(wav)                              # [1, frames, 80]
        x = self.trunk(feats)                                # [1, C, T']
        mean = x.mean(dim=-1)                                # [1, C]
        centred = x - x.mean(dim=-1, keepdim=True)
        var_biased = (centred * centred).mean(dim=-1)
        # unbiased correction N/(N-1) with N as a tensor (no shape arithmetic)
        n = torch.ones_like(x[:, :1, :]).sum(dim=-1)         # [1, 1] = T'
        var = var_biased * n / (n - 1.0)
        std = torch.sqrt(var + self.eps)
        pooled = torch.cat([mean.flatten(1), std.flatten(1)], dim=1)
        return (self.linear(pooled) - self.mean_vec).reshape(1, -1)


def fetch_wespeaker(cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, WESPEAKER_FILE)
    if not os.path.exists(path):
        print(f"  downloading {WESPEAKER_URL}")
        urllib.request.urlretrieve(WESPEAKER_URL, path)
    return path


def check_wespeaker(wrapper, onnx_path, seconds=2.5):
    """Wrapper must match onnxruntime fed with torchaudio's kaldi fbank."""
    import onnxruntime as ort
    import torchaudio.compliance.kaldi as kaldi

    torch.manual_seed(0)
    wav = torch.randn(1, int(seconds * SAMPLE_RATE)) * 0.1
    ref_feats = kaldi.fbank(wav * 32768.0, num_mel_bins=80, frame_length=25, frame_shift=10,
                            dither=0.0, sample_frequency=SAMPLE_RATE, window_type="hamming",
                            use_energy=False)
    ref_feats = (ref_feats - ref_feats.mean(0, keepdim=True)).unsqueeze(0)
    with torch.no_grad():
        mine_feats = wrapper.fbank(wav)
        ours = wrapper(wav).numpy()
    err = (mine_feats - ref_feats).abs().max().item()
    print(f"  conv1d fbank vs torchaudio kaldi.fbank: max abs err {err:.2e}")
    if err > 1e-2:
        raise RuntimeError("fbank front end diverges from torchaudio")
    sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    ref = sess.run(None, {"feats": ref_feats.numpy()})[0]
    c = cosine(ref, ours)
    print(f"  wrapper vs onnxruntime: cosine={c:.6f}")
    if c < 0.999:
        raise RuntimeError(f"wrapper diverges from ONNX reference (cosine {c:.4f})")
    return wav, ours


# ---------------------------------------------------------------------------
# SpeechBrain route (the plan's first choice; needs huggingface.co)
# ---------------------------------------------------------------------------

class ConvSTFT(nn.Module):
    """Drop-in for speechbrain.processing.features.STFT using conv1d with a
    windowed DFT kernel. Output layout matches SpeechBrain's: [B, T, n_fft/2+1, 2]."""

    def __init__(self, sb_stft):
        super().__init__()
        self.n_fft = int(sb_stft.n_fft)
        self.hop = int(sb_stft.hop_length)
        self.win = int(sb_stft.win_length)
        window = sb_stft.window_fn(self.win)
        if self.win < self.n_fft:
            left = (self.n_fft - self.win) // 2
            window = F.pad(window, (left, self.n_fft - self.win - left))
        n_bins = self.n_fft // 2 + 1
        n = torch.arange(self.n_fft, dtype=torch.float32)
        k = torch.arange(n_bins, dtype=torch.float32)
        angle = 2.0 * math.pi * torch.outer(k, n) / self.n_fft
        kernel = torch.cat([torch.cos(angle) * window, -torch.sin(angle) * window], dim=0).unsqueeze(1)
        self.register_buffer("kernel", kernel)
        self.n_bins = n_bins

    def forward(self, x):                                    # [B, L]
        y = F.conv1d(x.unsqueeze(1), self.kernel, stride=self.hop, padding=self.n_fft // 2)
        out = torch.stack([y[:, : self.n_bins, :], y[:, self.n_bins :, :]], dim=-1)   # [B, bins, T, 2]
        return out.transpose(1, 2)


class SpeechBrainEmbedder(nn.Module):
    """Fbank -> sentence mean-norm -> ECAPA-TDNN, as one traceable module."""

    def __init__(self, classifier, stft_mode):
        super().__init__()
        self.fbank = classifier.mods.compute_features
        self.embedding_model = classifier.mods.embedding_model
        norm = classifier.mods.mean_var_norm
        assert getattr(norm, "norm_type", "sentence") == "sentence", norm.norm_type
        self.std_norm = bool(getattr(norm, "std_norm", False))
        if stft_mode == "conv":
            self.fbank.compute_STFT = ConvSTFT(self.fbank.compute_STFT)
        self.output_dim = 192
        self.eval()

    def forward(self, waveform):                             # [1, T]
        feats = self.fbank(waveform)
        feats = feats - feats.mean(dim=1, keepdim=True)
        if self.std_norm:
            feats = feats / (feats.std(dim=1, keepdim=True) + 1e-10)
        return self.embedding_model(feats).reshape(1, -1)


def load_speechbrain(savedir):
    try:
        from speechbrain.inference.speaker import EncoderClassifier
    except ImportError:
        from speechbrain.pretrained import EncoderClassifier
    return EncoderClassifier.from_hparams(source=SPEECHBRAIN_SOURCE, savedir=savedir,
                                          run_opts={"device": "cpu"})


def check_speechbrain(classifier, wrapper, seconds=2.5):
    torch.manual_seed(0)
    wav = torch.randn(1, int(seconds * SAMPLE_RATE)) * 0.1
    with torch.no_grad():
        ref = classifier.encode_batch(wav).reshape(1, -1).numpy()
        ours = wrapper(wav).numpy()
    c = cosine(ref, ours)
    print(f"  wrapper vs speechbrain encode_batch: cosine={c:.6f}")
    if c < 0.999:
        raise RuntimeError(f"wrapper diverges from reference (cosine {c:.4f})")
    return wav, ours


# ---------------------------------------------------------------------------
# Core ML
# ---------------------------------------------------------------------------

def convert(wrapper, out_path, example, version, description):
    import coremltools as ct

    traced = torch.jit.trace(wrapper, example, check_trace=False)
    with torch.no_grad():
        alt = torch.randn(1, 3 * SAMPLE_RATE) * 0.1
        c = cosine(wrapper(alt).numpy(), traced(alt).numpy())
        print(f"  traced vs eager at a different length: cosine={c:.6f}")
        if c < 0.999:
            raise RuntimeError("trace did not generalise across time lengths")

    shape = ct.Shape(shape=(1, ct.RangeDim(lower_bound=MIN_SAMPLES, upper_bound=MAX_SAMPLES,
                                            default=DEFAULT_SAMPLES)))
    # fp16 weights/activations for the network, but the feature front end stays
    # fp32: Kaldi fbank works at int16 scale, so the power spectrum reaches
    # ~1e14 — far past fp16's 65504 — before the log tames it. Everything up to
    # and including the first `log` op is kept in float32.
    state = {"seen_log": False}

    def keep_fp16(op):
        if state["seen_log"]:
            return True
        if op.op_type == "log":
            state["seen_log"] = True
        return False

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="waveform", shape=shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.transform.FP16ComputePrecision(op_selector=keep_fp16),
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    if not state["seen_log"]:
        raise RuntimeError("expected a log op in the front end — precision split did not apply")
    mlmodel.author = description
    mlmodel.short_description = (f"Speaker embedding: 16 kHz mono waveform [1,T] -> "
                                 f"{wrapper.output_dim}-dim vector")
    mlmodel.version = version
    mlmodel.input_description["waveform"] = "16 kHz mono Float32 PCM in -1…1, shape [1, T], T in 8000…160000"
    mlmodel.output_description["embedding"] = "speaker embedding (cosine-compare after L2 normalisation)"
    if os.path.exists(out_path):
        shutil.rmtree(out_path)
    mlmodel.save(out_path)
    return mlmodel


def inspect(out_path, reference_wav=None, reference_emb=None):
    import coremltools as ct

    spec = ct.utils.load_spec(out_path)
    for i in spec.description.input:
        r = i.type.multiArrayType.shapeRange.sizeRanges
        print("  input :", i.name, [(x.lowerBound, x.upperBound) for x in r])
    for o in spec.description.output:
        print("  output:", o.name, list(o.type.multiArrayType.shape))
    print("  version:", spec.description.metadata.versionString)
    # Precision audit: the front end (through `log`) must be float32, the rest fp16.
    fn = spec.mlProgram.functions["main"]
    block = fn.block_specializations[fn.opset]
    dtypes = []
    for op in block.operations:
        if op.type == "const":
            continue
        t = op.outputs[0].type
        dt = t.tensorType.dataType if t.HasField("tensorType") else None
        dtypes.append((op.type, dt))
    from coremltools.proto import MIL_pb2
    fp16, fp32 = MIL_pb2.DataType.Value("FLOAT16"), MIL_pb2.DataType.Value("FLOAT32")
    log_index = [i for i, (ty, _) in enumerate(dtypes) if ty == "log"][0]
    front = dtypes[: log_index + 1]
    rest = dtypes[log_index + 1 :]
    fp32_front = all(dt in (fp32, None) or ty == "cast" for ty, dt in front)
    fp16_rest = sum(1 for _, dt in rest if dt == fp16)
    print(f"  precision: front end {len(front)} ops {'all fp32' if fp32_front else 'NOT all fp32!'}, "
          f"{fp16_rest}/{len(rest)} later ops fp16")
    if not fp32_front:
        raise RuntimeError(f"front end is not float32 — fp16 overflow risk: {front}")
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(out_path) for f in fs)
    print(f"  package size: {size / 1e6:.1f} MB")
    if sys.platform == "darwin" and reference_wav is not None:
        model = ct.models.MLModel(out_path)
        pred = model.predict({"waveform": reference_wav.numpy()})["embedding"]
        print(f"  Core ML vs torch: cosine={cosine(pred, reference_emb):.6f}")
    return size


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="SpeakerEmbedder.mlpackage")
    ap.add_argument("--source", choices=["wespeaker", "speechbrain"], default="wespeaker")
    ap.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "lmnh-speaker-model"))
    ap.add_argument("--stft", choices=["auto", "torch", "conv"], default="auto",
                    help="speechbrain only: how the STFT is expressed (auto: torch.stft, then conv1d)")
    args = ap.parse_args()
    t0 = time.time()
    print(f"▸ torch {torch.__version__}, source={args.source}")

    if args.source == "wespeaker":
        onnx_path = fetch_wespeaker(args.cache)
        print("▸ building wrapper (kaldi fbank + ResNet34 trunk + TSTP tail)")
        wrapper = WeSpeakerEmbedder(onnx_path)
        wav, emb = check_wespeaker(wrapper, onnx_path)
        print("▸ tracing + converting to Core ML (fp16, macOS 14+)")
        convert(wrapper, args.out, wav, WESPEAKER_VERSION,
                "WeSpeaker ResNet34-LM (VoxCeleb), via sherpa-onnx ONNX build; converted for Look Ma No Hands")
        print(f"▸ inspecting {args.out}")
        inspect(args.out, wav, emb)
        print(f"✓ wrote {args.out} in {time.time() - t0:.0f}s (modelVersion={WESPEAKER_VERSION}, dim={wrapper.output_dim})")
        return 0

    print(f"▸ loading {SPEECHBRAIN_SOURCE}")
    classifier = load_speechbrain(os.path.join(args.cache, "speechbrain"))
    classifier.eval()
    modes = ["torch", "conv"] if args.stft == "auto" else [args.stft]
    last_error = None
    for mode in modes:
        print(f"▸ building wrapper (stft={mode})")
        try:
            wrapper = SpeechBrainEmbedder(classifier, mode)
            wav, emb = check_speechbrain(classifier, wrapper)
            print("▸ tracing + converting to Core ML (fp16, macOS 14+)")
            convert(wrapper, args.out, wav, SPEECHBRAIN_VERSION,
                    "SpeechBrain ECAPA-TDNN (spkrec-ecapa-voxceleb), converted for Look Ma No Hands")
            print(f"▸ inspecting {args.out}")
            inspect(args.out, wav, emb)
            print(f"✓ wrote {args.out} in {time.time() - t0:.0f}s (stft={mode}, modelVersion={SPEECHBRAIN_VERSION})")
            return 0
        except Exception as e:                               # noqa: BLE001 — report and try the fallback
            last_error = e
            print(f"  ! stft={mode} failed: {type(e).__name__}: {e}", file=sys.stderr)
    print(f"✗ conversion failed: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
