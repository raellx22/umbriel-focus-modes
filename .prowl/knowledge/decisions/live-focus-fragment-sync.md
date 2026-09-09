---
type: Decision
title: Live focus synchronization via validated Umbriel config fragments
tags: [umbriel, noctalia, focus]
prowl:
    anchors:
        - path: umbriel-focus-modes/service.luau
          line_start: 160
          line_end: 225
          content_hash: sha256:b5f9dfec116415706faa142e456af03fdb5b54bae5624b44b51f6c15ce7f9e5f
---
Umbriel does not expose a live msg action to toggle follows_mouse, but automatically reloads valid included TOML fragments. The plugin synchronizes focus by writing ~/.config/umbriel/umbriel-focus-modes.toml through atomic staging and dual validation (staged fragment validation plus full umbriel validate) to prevent reload loops and broken states. Cross-output focus transitions are polled with a 500ms fallback because Umbriel does not emit workspace events on mouse-crossing without window refocus.
