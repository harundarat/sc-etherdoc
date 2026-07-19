# Testing

Etherdoc separates deterministic PR checks from tests that depend on live networks:

- unit and negative tests cover authorization, configuration, lifecycle, events, Router/token
  failures, replay, malformed envelopes, and payload validation;
- fuzz tests exercise canonical CID/digest combinations, independent issuers, fee/config bounds,
  EIP-712 signatures, payload bounds, and multiple destination lanes;
- handler-based invariant tests randomize active/revoked delivery and replay ordering while tracking
  monotonic destination state;
- local multichain tests use Router harnesses and never depend on an RPC;
- optional fork tests verify current Router/LINK bytecode, lane support, and ExtraArgs V3 quotes in
  both directions;
- the scheduled testnet E2E workflow registers a unique document, dispatches it, and polls the
  destination receipt. It is deliberately separate from PR CI.

## Local commands

```shell
forge fmt --check
forge lint --deny warnings src script test
bash script/check-contract-sizes.sh
bash script/check-gas-snapshot.sh
forge test -vv
FOUNDRY_PROFILE=ci forge test -vv
bash script/check-coverage.sh
bash script/ci-deployment-dry-run.sh
```

Invariant tests are excluded only from the coverage command because their paths are already covered
by deterministic tests; they remain mandatory in both normal and CI-profile `forge test` runs.
Coverage is scoped to `src/`, not vendored dependencies, scripts, mocks, or test harnesses.
`check-coverage.sh` enforces 100% line, statement, branch, and function coverage. The gas snapshot
tracks registration, fee-protected dispatch, and local end-to-end delivery with a 5% tolerance.
Contract size budgets are deliberately below the EIP-170/EIP-3860 limits and require explicit review
when raised.

PR CI also runs Slither 0.11.5 through a fully pinned Slither action. Findings from `lib/`, scripts,
and tests are filtered while dependencies remain available for compilation. Medium-or-higher
production findings fail the job. `incorrect-equality` is explicitly triaged because strict enum,
digest, and document-ID equality is required by Etherdoc's lifecycle and integrity checks.

The Anvil deployment smoke test executes both deploy scripts with representative nonzero governance
roles, validates configured Router/LINK bytecode, and asserts that the dry-run does not increment the
deployer nonce. It never broadcasts a transaction.

## Optional live fork checks

The tests skip clearly when their corresponding RPC is absent:

```shell
MANTLE_SEPOLIA_RPC_URL=<rpc-url> \
INK_SEPOLIA_RPC_URL=<rpc-url> \
  forge test --match-path test/CCIPV2Fork.t.sol -vv
```

The fork tests do not broadcast or require funded accounts.

## Periodic testnet E2E

`.github/workflows/testnet-e2e.yml` has no pull-request trigger. It runs weekly or manually only when
the repository variable `CCIP_E2E_ENABLED` is exactly `true`. Configure a protected
`testnet-e2e` GitHub Environment with:

- `MANTLE_SEPOLIA_RPC_URL` and `INK_SEPOLIA_RPC_URL`;
- `CCIP_E2E_PRIVATE_KEY`, a dedicated testnet-only key;
- `MANTLE_SEPOLIA_SENDER` and `INK_SEPOLIA_RECEIVER`.

The dedicated account must have Mantle gas, be an authorized issuer and operator, while the sender
must have enough LINK. The deployed receiver must already trust the Mantle selector/sender pair.
The workflow fails before broadcasting if those roles or the trusted pair are missing. It then:

1. derives a unique raw CID from the workflow run and timestamp;
2. registers the document on Mantle Sepolia;
3. obtains a live quote and dispatches with a 25% fee ceiling buffer;
4. extracts the indexed CCIP `messageId` from `MessageSent`;
5. polls Ink Sepolia for up to 45 minutes and verifies that the message resolves to the expected
   document ID.

For local invocation, export the variables used by the workflow and run:

```shell
bash script/testnet-e2e.sh
```

Never use a mainnet key or an account holding production funds for this check.
