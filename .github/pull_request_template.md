# What this changes

<!-- One paragraph, or none if it is obvious from the title. -->

## Why

<!-- The reason, if it is not obvious. -->

## How it was tested

<!-- What you ran, and what you saw. -->

## Checklist

- [ ] `cargo test` and `cargo clippy --all-targets -- -D warnings` pass
- [ ] `python3 -m unittest discover -s scripts/tests` passes, if the change touched the scripts
- [ ] `swift build -c release --package-path app` passes, if the change touched the app
- [ ] The README is updated, if the change is visible to a user
- [ ] `python3 scripts/notices.py` was run, if a dependency changed
