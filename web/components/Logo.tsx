/**
 * The brand mark, inlined rather than loaded as an image.
 *
 * Geometry is copied from Assets/mark.svg — five capsules that read as a raised
 * hand one way and an audio level meter the other. It's stroked in
 * `currentColor`, so it takes the colour of whatever it sits in and needs no
 * separate light/dark asset. Keep the two files in step if the shape changes.
 */
export function Mark({ size = 24, className }: { size?: number; className?: string }) {
  return (
    <svg
      viewBox="197 312 614 400"
      width={size}
      height={(size * 400) / 614}
      className={className}
      role="img"
      aria-label="Look Ma, No Hands"
    >
      <g
        fill="none"
        stroke="currentColor"
        strokeWidth={76}
        strokeLinecap="round"
      >
        <path d="M344 654 L255 486" />
        <path d="M434 430 V654" />
        <path d="M546 370 V654" />
        <path d="M658 410 V654" />
        <path d="M770 490 V654" />
      </g>
    </svg>
  );
}

/** Mark plus wordmark, for the nav. */
export function Lockup() {
  return (
    <span className="lockup">
      <Mark size={30} />
      <span>Look Ma, No Hands</span>
    </span>
  );
}
