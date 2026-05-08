import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { installChangeflowBridge } from "./src/bridge.js";

export default function changeflow(pi: ExtensionAPI): void {
  installChangeflowBridge(pi);
}
