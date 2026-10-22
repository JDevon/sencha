# Changelog

## 0.2.0

- Client prediction:
  - `prediction` on replicators, and `fireServerPredicted` / `invokeServerPredicted` on reliable remotes.
  - `get`, `getAsync`, `observe`, `onChanged` and `getObservable` include pending predictions on the client.
  - `getConfirmed` and `onConfirmedChanged` on replicators, for the server's value without predictions.
  - New exported type: `Sencha.Prediction`.

## 0.1.0

- Initial release:
  - Remotes: `event`, `unreliableEvent`, `func`, `eventSwitchboard` and `funcSwitchboard`, with GreenTea type checks,
    per-player rate limits and rejected-call warnings.
  - Replicators: saved (from a saved source), `temporaryReplicator.player` and `temporaryReplicator.global`, with
    optional incremental updates.
  - `tryUpdate` on temporary replicators, for changing a value based on its current value without yielding.
  - `getObservable` on replicators, for use with ObservableValue and ReactObservableValue.
