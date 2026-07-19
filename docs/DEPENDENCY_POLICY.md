# Dependency Policy

Etherdoc pins Solidity dependencies by full Git commit through submodules. A release tag or package
version is recorded for review, but the Git commit is the reproducible source of truth. Clone and
update the repository recursively:

```shell
git clone --recurse-submodules <repository-url>
git submodule sync --recursive
git submodule update --init --recursive
```

## Approved compatibility matrix

The Chainlink matrix follows the exact production dependencies declared by
[`@chainlink/local` 0.2.9](https://github.com/smartcontractkit/chainlink-local/releases/tag/v0.2.9):

| Dependency | Version/tag | Full commit |
|---|---|---|
| `@chainlink/local` | `v0.2.9` | `f8c0efe8685660dac07e08f4558f1b578ae991aa` |
| `@chainlink/contracts` | `contracts-v1.5.0` | `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba` |
| `@chainlink/contracts-ccip` | `contracts-ccip-v1.6.2` | `0e3e0fc5c0f70f0d50dca66b139142ddf3009294` |
| `forge-std` | `v1.9.7` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |

Chainlink Local declares Contracts `1.5.0` and CCIP `1.6.2` as exact dependencies and pins those
repositories as nested submodules. Root remappings therefore use the nested copies as the single
source of Chainlink contracts. The former vendored `chainlink-brownie-contracts` 1.3.0 tree and
duplicate root CCIP submodule are intentionally absent.

The root and Chainlink Local each retain a `forge-std` checkout because both are direct development
dependencies. They resolve to the same full commit, while the root `forge-std/` import remapping is
unambiguous. OpenZeppelin imports use the versioned `@openzeppelin/contracts@5.0.2` alias supplied
by Chainlink Local instead of relying on a removed Chainlink vendor path.

CCIP 2.x is not part of this matrix. It is a separate migration because its protocol and contract
interfaces require dedicated compatibility, deployment, and in-flight-message analysis.

## Update requirements

Dependency changes must be submitted for review and must not auto-merge. A change must:

1. select a published compatibility matrix and pin every submodule to a full commit;
2. update this table and the explicit remappings without adding competing copies;
3. inspect release notes and diffs for interface, storage, event, fee, and message-format changes;
4. run `forge fmt --check`, `forge build --sizes`, and the complete `forge test -vv` suite;
5. exercise `test/Integration.t.sol` so the approved Local simulator sends and receives an
   application payload; and
6. use a new deployment and controlled remote rotation for an incompatible CCIP or storage change.

Reviewers can compare the checked-out content identifiers with this policy using:

```shell
git submodule status --recursive
git -C lib/chainlink-local show HEAD:package.json
git -C lib/chainlink-local/lib/chainlink-evm show HEAD:contracts/package.json
git -C lib/chainlink-local/lib/chainlink-ccip show HEAD:chains/evm/package.json
```
