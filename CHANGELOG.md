# Changelog

## 0.1.0

- Initial release:
  - Remotes: `event`, `unreliableEvent`, `func`, `eventSwitchboard` and `funcSwitchboard`, with GreenTea type checks,
    per-player rate limits and rejected-call warnings.
  - Replicators: saved (from a saved source), `temporaryReplicator.player` and `temporaryReplicator.global`, with
    optional incremental updates.
  - `getObservable` on replicators, for use with ObservableValue and ReactObservableValue.
