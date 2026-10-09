// The cross-stack PPG anchor golden written by the Swift NoopPush suite (PpgAnchorTransportTests):
// the phone encoder's own bytes, never a second encoder's guess at them.
export const PPG_ANCHOR_GOLDEN = JSON.parse(await Deno.readTextFile(new URL(
  '../../../Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json', import.meta.url)));
export const unhex = (hex: string) => Uint8Array.from(hex.match(/../g)!, (pair) => parseInt(pair, 16));
export const vector = (name: string) => PPG_ANCHOR_GOLDEN.vectors.find((v: any) => v.name === name);
