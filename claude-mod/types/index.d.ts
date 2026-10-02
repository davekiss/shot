// `what` is the row's one-line answer to "what is this a picture of": shot's
// description when there is one, else the app and window, else the file's name.
export type Shot = { path: string; name: string; mtimeMs: number; size: number; what: string; isDescribed: boolean }

declare module 'claude-code' {
  interface PluginState {
    shot: { shots: Shot[]; selected: string | null; notice: { path: string; text: string } | null }
  }
}
