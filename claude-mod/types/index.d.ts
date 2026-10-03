// `what` is the row's one-line answer to "what is this a picture of": shot's
// description when there is one, else the app and window, else the file's name.
export type Shot = { path: string; name: string; mtimeMs: number; size: number; what: string; isDescribed: boolean }

// A shot an agent just took or edited, for the strip above the prompt.
export type Recent = { path: string; verb: 'captured' | 'edited'; at: number }

declare module 'claude-code' {
  interface PluginState {
    shot: { shots: Shot[]; selected: string | null; recent: Recent[]; isStripHidden: boolean }
  }
}
