# Repository Guidelines

## Project Structure & Module Organization

Production Solidity contracts live in `src/`. Foundry tests are in `test/`; shared helpers and protocol doubles belong in `test/utils/` and `test/mocks/`. Deployment and administration contracts, plus CI shell checks, live in `script/`. Network inputs and check budgets are under `config/networks/` and `config/ci/`. Keep operational or protocol explanations in `docs/`. Dependencies in `lib/` are pinned Git submodules—do not edit vendored code directly. Generated deployment manifests belong under `deployments/`.

## Build, Test, and Development Commands

Use the Foundry version pinned in `.foundry-version` and initialize submodules before building:

```shell
git submodule update --init --recursive
foundryup --install "$(cat .foundry-version)"
forge build
forge test -vv
forge fmt --check
forge lint --deny warnings src script test
```

Before submitting, run `bash script/check-coverage.sh`, `bash script/check-contract-sizes.sh`, and `bash script/check-gas-snapshot.sh`. Changes to deployment logic should also pass `bash script/ci-deployment-dry-run.sh` and `bash script/test-deployment-workflow.sh`. `FOUNDRY_PROFILE=ci forge test -vv` uses CI-strength fuzz and invariant settings.

## Coding Style & Naming Conventions

All project Solidity uses exact pragma `0.8.36`, four-space indentation, and `forge fmt`. Use PascalCase for contracts, structs, events, and custom errors; camelCase for functions and variables; and uppercase snake case for constants. Name tests `test_<behavior>`, fuzz cases `testFuzz_<behavior>`, and invariants `invariant_<property>`. Prefer explicit custom errors and events for externally observable state changes. Preserve the Paris EVM target and optimizer settings in `foundry.toml`.

## Testing Guidelines

Add tests beside the closest behavior-focused suite, using mocks only for external dependencies. Cover success, authorization, revert, replay, and lifecycle edge cases. Coverage checks enforce 100% line, statement, branch, and function coverage for `src/`. Fork tests in `test/CCIPV2Fork.t.sol` are optional locally and require both configured testnet RPC URLs; ordinary tests must remain deterministic and RPC-independent.

## Commit & Pull Request Guidelines

History follows Conventional Commit-style subjects such as `feat:`, `fix(ci):`, `test:`, and `docs:`. Keep subjects imperative, scoped, and limited to one logical change. Pull requests should explain behavior and security impact, link relevant issues, and list commands run. Include updated gas snapshots, size budgets, deployment tests, configuration, or protocol documentation whenever the change affects those artifacts.

## Security & Configuration

Never commit private keys, RPC secrets, or production credentials. Copy `.env-example` to `.env` locally. Treat dependency upgrades, cross-chain payload changes, governance roles, Router addresses, and network selectors as security-sensitive changes requiring explicit review and the checks in `docs/DEPENDENCY_POLICY.md`.
