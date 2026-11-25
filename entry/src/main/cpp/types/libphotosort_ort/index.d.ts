export const embed: (model: ArrayBuffer, tokenIds: number[]) => Promise<Float32Array>;
export const rankScenes: (model: ArrayBuffer, pixels: ArrayBuffer) => Promise<Float32Array>;
