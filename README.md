# Manifold

Professional stream review for colorists. A native macOS app for DC Color Live and beyond.

**Bundle ID:** com.graviton.manifold

## Run a build of this working tree

`scripts/run.sh` builds the tree (Profile) into the gitignored `.build-run/` and launches it, logging to `$CODE_ROOT/_scratch/manifold-run/manifold-run.log` (`CODE_ROOT` defaults to `~/Code`; overwritten each run).
`scripts/run.sh --no-build` relaunches the last build; either refuses while a `.build-run/` Manifold is still running, so quit that one first.
