# Contributing

Thanks for helping. This app handles people's only copies of their photos, so changes are reviewed with care.

## How changes get in

- **Nobody pushes to `main`.** The branch is protected; every change, the maintainer's included, arrives as a pull request.
- **Found a bug or have an idea?** [Open an issue](../../issues/new/choose) first. For anything bigger than a small fix, wait for a reply on the issue before writing code, so your time isn't wasted.
- **Sending a fix?** Fork the repo, make a branch, and open a pull request against `main`. Link the issue it closes.

## Before you open a pull request

1. `swift build` succeeds.
2. `swift run SelfTest` prints `ALL CHECKS PASSED`. New logic in `Sources/Core` comes with a check in `Sources/SelfTest` (register new test files in `main.swift`).
3. If you changed what the app shows, add a screenshot to the pull request. You can use demo mode (see the README) instead of a real iPhone.

## Ground rules

- **Never weaken the safety rules.** Read the "Safety invariants" section of [CLAUDE.md](CLAUDE.md) before touching backing up, matching, or deleting. A change that could lose a photo will not be merged, however useful it is otherwise.
- **Plain words in the app.** "Fingerprint", not "hash"; "hard disk", not "volume". The app is made for people who aren't technical.
- **Small pull requests.** One fix or feature each.
- **AI-assisted contributions are welcome.** Contributors remain responsible for understanding, testing, and explaining every change included in a pull request.

## Reporting a security or privacy problem

If you find a way the app could lose photos or leak them, open an issue, but leave out exploit details and anything personal. The maintainer will follow up.

By contributing, you agree your work is released under the [MIT License](LICENSE).
