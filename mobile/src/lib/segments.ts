/**
 * Utterance segmentation for continuous speech recognition. Pure.
 *
 * iOS delivers continuous-mode results as one CUMULATIVE transcript with
 * isFinal essentially never true mid-session, so anything keyed on final
 * results (wake commands, stop phrases, dictation) never fires — the screen
 * shows words while the app stays deaf to them. The fix is to cut segments
 * ourselves: the hook calls `takeSegment` when the transcript has been silent
 * for a beat, and whatever text arrived since the last cut is the utterance.
 */

export interface SegmentCut {
  /** The new utterance since the last cut; "" when nothing new arrived. */
  segment: string;
  /** Pass this back as `processed` on the next call. */
  processed: number;
}

/**
 * Cut the unprocessed tail off a cumulative transcript. A transcript SHORTER
 * than what was already processed means the engine restarted (its backstop
 * restart, or a fresh session) and the counter starts over — the new text is
 * all unprocessed.
 */
export function takeSegment(processed: number, transcript: string): SegmentCut {
  const base = transcript.length < processed ? 0 : processed;
  return {
    segment: transcript.slice(base).trim(),
    processed: transcript.length,
  };
}
