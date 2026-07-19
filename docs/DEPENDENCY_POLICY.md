# Dependency Policy

Etherdoc pins Solidity dependencies by full Git commit through root submodules. A release tag or
package version is recorded for review, but the Git commit is the reproducible source of truth.
Clone and update the repository recursively:

```shell
git clone --recurse-submodules <repository-url>
git submodule sync --recursive
git submodule update --init --recursive
```

## Approved CCIP 2.0 matrix

| Dependency | Version/tag | Full commit |
|---|---|---|
| `@chainlink/contracts-ccip` | `contracts-ccip-v2.0.0` | `c2c125c27f056db2e98d21501922b6eff5750f36` |
| `@chainlink/contracts` | `contracts-v1.5.0` | `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba` |
| `@openzeppelin/contracts` | `v5.3.0` | `e4f70216d759d8e6a64144a9e1f7bbeed78e7079` |
| `forge-std` | `v1.16.2` | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |

Chainlink CCIP, Chainlink Contracts, OpenZeppelin, and forge-std are direct root submodules.
Chainlink Local and its nested CCIP 1.6.2 checkout are intentionally absent. Root remappings resolve
each import prefix to exactly one checkout:

```text
@chainlink/contracts/=lib/chainlink-evm/contracts/
@chainlink/contracts-ccip/=lib/chainlink-ccip/chains/evm/
@openzeppelin/contracts@5.3.0/=lib/openzeppelin-contracts/contracts/
```

Application code uses the versioned OpenZeppelin 5.3.0 prefix. Tests use a small local ERC-20 fee
token instead of Chainlink Local so production protocol types come only from the pinned CCIP 2.0
repository. `test/Integration.t.sol` supplies an immediate-delivery Router harness that validates
ExtraArgs V3, full finality, the default CCV/executor selection, LINK fee collection, and
destination delivery.

This is a clean cutover. Etherdoc has no mainnet deployment, persisted contract state, or pending
message that needs v1 compatibility. Old deployment artifacts and CCIP 1.x messages are not
accepted as migration inputs.

## Compiler and Foundry toolchain

The application build is reproducible at these exact settings:

| Tool/setting | Pinned value |
|---|---|
| Foundry | `v1.7.1` (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`) |
| Solidity | `0.8.36` (`8a079791d9cca7a6c03fd6a8429b93aa3bddefed`) |
| EVM target | `paris` |
| Optimizer | enabled, 200 runs, non-IR pipeline |
| `foundry-toolchain` action | `b00af27efadbc7b4ca8b82abbd903b17cc874d2a` (`v1.9.0`) |
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` (`v4.3.1`) |

`.foundry-version` is the local source of truth for the Foundry release. CI installs the same exact
release and asserts that the installed `forge` version matches the file. `foundry.toml` pins the
compiler, EVM target, optimizer, and optimizer runs for every profile; the CI profile only increases
fuzz and invariant effort.

Paris is deliberate even though Solidity supports newer targets. It matches the upstream CCIP 2.0
Foundry configuration and avoids emitting chain-specific newer opcodes while Etherdoc spans
heterogeneous EVM networks. Compiler warnings originating in pinned `lib/` dependencies are excluded
from application output; warnings from `src/`, `script/`, and `test/` remain visible.

## Update requirements

Dependency changes must be submitted for review and must not auto-merge. A change must:

1. select published releases and pin every submodule to a full commit;
2. update this table and explicit remappings without adding competing copies;
3. inspect release notes and diffs for interface, storage, event, fee, verifier, executor, finality,
   and message-format changes;
4. verify each target lane and Router against the current CCIP Directory;
5. run `forge fmt --check`, `forge build --sizes`, and the complete `forge test -vv` suite using the
   Foundry version in `.foundry-version`;
6. exercise `test/Integration.t.sol` and both optional live Router fork tests; and
7. use new deployments and controlled remote rotation for any incompatible CCIP or storage change.

Reviewers can compare checked-out content identifiers with this policy using:

```shell
git submodule status
git -C lib/chainlink-ccip rev-parse HEAD
git -C lib/chainlink-evm rev-parse HEAD
git -C lib/openzeppelin-contracts rev-parse HEAD
git -C lib/forge-std rev-parse HEAD
```

CCIP 2.0 concepts and security choices for Etherdoc:

- an empty CCV list selects the default CommitteeVerifier;
- `address(0)` selects the default executor;
- `WAIT_FOR_FINALITY_FLAG` requires full finality and does not opt into FTF;
- the default executor is automated, while destination execution remains permissionless;
- `NO_EXECUTION_TAG` is not used; and
- custom CCVs, custom executors, and token transfers require a separate reviewed change.

See the
[CCIP 2.0 release](https://github.com/smartcontractkit/chainlink-ccip/releases/tag/contracts-ccip-v2.0.0)
for the protocol-level model.
