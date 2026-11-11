import type { ReactNode, SVGProps } from "react";

type IconProps = SVGProps<SVGSVGElement> & { size?: number };

function Svg({ size = 18, children, ...rest }: IconProps & { children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      {children}
    </svg>
  );
}

export const FolderPlusIcon = (p: IconProps) => <Svg {...p}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /><path d="M12 10v6M9 13h6" /></Svg>;
export const FilePlusIcon = (p: IconProps) => <Svg {...p}><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5M12 11v6M9 14h6" /></Svg>;
export const FolderOpenIcon = (p: IconProps) => <Svg {...p}><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v1" /><path d="M3 7v10a2 2 0 0 0 2 2h12.5a2 2 0 0 0 1.9-1.4L21.8 11H7.2a2 2 0 0 0-1.9 1.4L3 19" /></Svg>;
export const GripIcon = (p: IconProps) => <Svg {...p} strokeWidth={0} fill="currentColor"><circle cx="9" cy="6" r="1.6" /><circle cx="15" cy="6" r="1.6" /><circle cx="9" cy="12" r="1.6" /><circle cx="15" cy="12" r="1.6" /><circle cx="9" cy="18" r="1.6" /><circle cx="15" cy="18" r="1.6" /></Svg>;
export const ArrowUpIcon = (p: IconProps) => <Svg {...p}><path d="M12 19V5M6 11l6-6 6 6" /></Svg>;
export const ArrowDownIcon = (p: IconProps) => <Svg {...p}><path d="M12 5v14M6 13l6 6 6-6" /></Svg>;
export const CloseIcon = (p: IconProps) => <Svg {...p}><path d="M6 6l12 12M18 6 6 18" /></Svg>;
export const PlayIcon = (p: IconProps) => <Svg {...p} strokeWidth={0} fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.86l12.5-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z" /></Svg>;
export const PauseIcon = (p: IconProps) => <Svg {...p} strokeWidth={0} fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1" /><rect x="14" y="4" width="4" height="16" rx="1" /></Svg>;
export const FrameBackIcon = (p: IconProps) => <Svg {...p}><path d="M6 5v14M18 6l-8 6 8 6z" /></Svg>;
export const FrameForwardIcon = (p: IconProps) => <Svg {...p}><path d="M18 5v14M6 6l8 6-8 6z" /></Svg>;
export const ToStartIcon = (p: IconProps) => <Svg {...p}><path d="M5 5v14M19 6l-9 6 9 6z" /></Svg>;
export const ToEndIcon = (p: IconProps) => <Svg {...p}><path d="M19 5v14M5 6l9 6-9 6z" /></Svg>;
export const VolumeIcon = (p: IconProps) => <Svg {...p}><path d="M4 9h4l5-4v14l-5-4H4z" /><path d="M16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" /></Svg>;
export const MuteIcon = (p: IconProps) => <Svg {...p}><path d="M4 9h4l5-4v14l-5-4H4z" /><path d="m17 9 5 6M22 9l-5 6" /></Svg>;
export const ExpandIcon = (p: IconProps) => <Svg {...p}><path d="M4 9V4h5M15 4h5v5M4 15v5h5M20 15v5h-5" /></Svg>;
export const UndoIcon = (p: IconProps) => <Svg {...p}><path d="M9 14 4 9l5-5" /><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11" /></Svg>;
export const RedoIcon = (p: IconProps) => <Svg {...p}><path d="m15 14 5-5-5-5" /><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13" /></Svg>;
export const CheckIcon = (p: IconProps) => <Svg {...p}><path d="m5 12.5 4.5 4.5L19 7.5" /></Svg>;
export const AlertIcon = (p: IconProps) => <Svg {...p}><path d="M12 3.5 2.5 20h19z" /><path d="M12 10v4.5M12 17.5h0" /></Svg>;
export const CopyIcon = (p: IconProps) => <Svg {...p}><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" /></Svg>;
export const ImageIcon = (p: IconProps) => <Svg {...p}><rect x="3" y="5" width="18" height="14" rx="2" /><circle cx="9" cy="10" r="1.8" /><path d="m21 16-5-5-9 8" /></Svg>;
export const LinkIcon = (p: IconProps) => <Svg {...p}><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" /><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" /></Svg>;
export const ChevronLeftIcon = (p: IconProps) => <Svg {...p}><path d="m15 6-6 6 6 6" /></Svg>;
export const ChevronRightIcon = (p: IconProps) => <Svg {...p}><path d="m9 6 6 6-6 6" /></Svg>;
export const ScissorsIcon = (p: IconProps) => <Svg {...p}><circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><path d="M8 7.5 20 18M8 16.5 20 6" /></Svg>;
export const ExportIcon = (p: IconProps) => <Svg {...p}><path d="M12 15V3M7 8l5-5 5 5" /><path d="M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5" /></Svg>;
export const FilmIcon = (p: IconProps) => <Svg {...p}><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M7 4v16M17 4v16M3 9h4M3 15h4M17 9h4M17 15h4" /></Svg>;
