# Release gates

Phase 0 is the prerequisite for v0.1. Every release is evaluated in RU/EN, System/Light/Dark, compact/wide layouts and relevant accessibility settings. Benchmarks use a Release build, the fixed Research corpus and control Mac. Investigate increases above 20% in median time or peak memory for the same scenario before release. Store raw five-run data and the actual signing status. Never infer a pass from missing measurements.

| Release | Visual | Performance | Usability |
|---|---|---|---|
| Phase 0 Foundation | Library/Reader/popovers at 800/1440 pt, legible text and focus, native motion with accessibility alternatives | Process launch, panel interaction, scroll CPU frames/intervals, memory, Color Engine vs Original | Keyboard panels/popovers with focus return, VoiceOver names/state, restart restores workspace |
| v0.1 Offline PDF | Text, diagrams and photos in each palette; Original fallback reachable | Large-PDF first display/scroll; background pages preserve responsiveness | Offline copy/reference import, search, bookmark, Focus, Keep Awake, position restore; source checksum unchanged; closing releases display assertion |
| v0.2 Daily reading | Spotlight surroundings legible, Mini Reader/timer/Command Center compact | 25-minute Mini Reader/autoscroll session; no surviving timers/tasks after close | Smart Back from footnote, scheduled palette, pause, manual gesture stops scrolling; Cmd-K offline |
| v0.3 PDF AI | Citations/navigation clear; Magic Selection visible; Smart Margins hidden by default in Read/Focus | Scroll while indexing/responding; cancellation stops work | Local and explicitly enabled cloud modes, citations/Explain Again point to paragraph, topic switch, reversible note, scan-without-text behavior |
| v0.4 EPUB and learning | Reflow preserves highlights, footnotes and illustrations | Long chapter open/reflow/locator; speech remains responsive | Note/card survives font change and restart with same source; Recall, card editing, Markdown export, Listen & Read resume |
| v0.5 Connected knowledge | Citation, reader note and model inference distinguishable in search/Canvas | Fixed-library cross-book search and board manipulation | Compare two sources, save relation, Timeline event, edit suggested route, export |
| v0.6 Extended reading | Active split pane, bilingual alignment, low-confidence OCR marked at text | Two-book memory and scroll during OCR; cancel releases resources | Independent scrolling, OCR-to-scan navigation, disable/clear Replay and Insights |
| v1.0 Stable public | Core workflows across languages, appearances, window sizes and accessibility | Minimum supported OS: launch, large files, search, long reading; regressions resolved | Clean-Mac install/offline use; update retains library/notes/relations; GitHub release includes binary, checksum, changelog and actual signing status |

v0.4 application-source gates passed at `0c5d73c`: [acceptance report](v0.4.md), [Release measurements](../Research/v0.4/README.md), [full CI](https://github.com/karavaevflow/adaptive-reader/actions/runs/43243196440). The distributed binary is built from that revision. v0.5 has not started.
