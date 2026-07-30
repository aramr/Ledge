# Contributing to Ledge

Thanks for helping improve Ledge.

## Before opening a change

- Search existing issues and pull requests first.
- Open an issue before starting a large feature or architectural change.
- Keep pull requests focused and avoid unrelated formatting changes.
- Never commit credentials, signing material, generated build products, or user data.

## Development

Ledge requires macOS 15 or later and Xcode 26 or later.

```sh
git clone https://github.com/aramr/Ledge.git
cd Ledge
Scripts/ci.sh
```

You can also open `MacDynamicIsland.xcodeproj`, select the Ledge scheme, and run the app on My Mac. Debug builds use `com.aramrahimi.Ledge.debug`; production releases use `com.aramrahimi.Ledge`.

## Pull requests

Every pull request should:

- explain the user-visible behavior and motivation;
- include tests for new model or service behavior where practical;
- pass `Scripts/ci.sh`;
- preserve the local-first privacy model described in `PRIVACY.md`;
- update documentation when installation, settings, or user-facing behavior changes.

By contributing, you agree that your contribution is licensed under the MIT License.
