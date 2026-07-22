# Deployment and Configuration

Etherdoc deployment automation is deliberately split by responsibility:

- `deploy-contract.sh sender|receiver` deploys exactly one contract role and records its receipt;
- `ConfigureEtherdocRemotes.s.sol` reconciles either side of a lane with the desired config;
- `ManageEtherdocTreasury.s.sol` reconciles the sender LINK balance with a funding or retention
  target;
- `verify-contract.sh sender|receiver` verifies the exact artifact and constructor arguments from
  the deployment manifest.

Every command reads addresses and selectors from `NETWORK_CONFIG_PATH`. No network or Etherdoc
deployment address is embedded in a script.

## Network and governance modes

Every network entry must include:

```json
{
  "governanceMode": "DIRECT",
  "production": false
}
```

`DIRECT` is intended only for local and test environments where the broadcast signer owns the
contract. A production entry must set `production: true` and `governanceMode: "MULTISIG"`;
`NetworkConfigScript` rejects any production/direct combination. Deployment also rejects a
`GOVERNANCE` address without bytecode in multisig mode.

Multisig configuration and withdrawal runs never broadcast an owner call. Instead they write a Safe
Transaction Builder compatible JSON batch under
`PROPOSAL_DIR/<network>/<operation>.json`. Review its chain ID, Safe address, target, zero value, and
calldata before importing it into Safe and collecting the configured threshold. Running the same
operation again preserves an identical proposal rather than producing duplicates.

## Deploy one role

Use a clean, committed worktree so the recorded Git commit identifies the exact source. The wrapper
checks the RPC chain ID, invokes the role-specific Solidity script, reconciles the saved address with
the transaction receipt and on-chain code, then creates a manifest.

Use an encrypted Foundry account or hardware wallet; do not put a production private key in `.env`.

```shell
# Source sender
NETWORK=mantleSepolia \
RPC_URL="$MANTLE_SEPOLIA_RPC_URL" \
  bash script/deploy-contract.sh sender --account deployer

# Destination receiver, bound to the deployed canonical source
NETWORK=inkSepolia \
SOURCE_NETWORK=mantleSepolia \
RPC_URL="$INK_SEPOLIA_RPC_URL" \
  bash script/deploy-contract.sh receiver --account deployer
```

The wrapper supplies `--broadcast` itself. A rerun reads
`DEPLOYMENT_DIR/<network>.json`, verifies the saved contract's bytecode and Router/LINK dependencies,
and creates no transaction. It refuses to backfill a missing manifest because an address alone
cannot prove the original creation transaction or constructor arguments.

Each `DEPLOYMENT_DIR/manifests/<network>-<role>.json` contains:

- network, role, contract artifact, address, chain ID, and chain selector;
- creation transaction hash, block number, block timestamp, deployer, and runtime code hash;
- Git commit and dirty-worktree flag;
- compiler version, EVM version, optimizer settings;
- decoded and ABI-encoded constructor arguments;
- manifest schema version and generation timestamp.

Archive the address books, manifests, Safe proposals, verification result, and explorer links in the
release/operations record. They are generated environment artifacts and are intentionally ignored
by Git.

## Configure both sides of a lane

The receiver constructor establishes the canonical selector, source chain ID, and initial sender.
The configuration script reconciles later sender rotations and configures destination routing on
the source:

```shell
# Destination reconciles a rotated source sender (normally a no-op after initial deployment)
SOURCE_NETWORK=mantleSepolia \
DESTINATION_NETWORK=inkSepolia \
CONFIGURE_TARGET=RECEIVER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url ink_sepolia --broadcast --account governance

# Source routes to destination receiver
SOURCE_NETWORK=mantleSepolia \
DESTINATION_NETWORK=inkSepolia \
CONFIGURE_TARGET=SENDER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url mantle_sepolia --broadcast --account governance
```

For `MULTISIG`, omit `--broadcast` and wallet flags. The same commands perform local and remote
bytecode preflight, then write Safe proposal JSON instead of impersonating the multisig:

```shell
SOURCE_NETWORK=mantle \
DESTINATION_NETWORK=ink \
CONFIGURE_TARGET=SENDER \
  forge script script/ConfigureEtherdocRemotes.s.sol:ConfigureEtherdocRemotesScript \
    --rpc-url "$MANTLE_RPC_URL"
```

After Safe execution, rerun the command. It must report that the remote is already configured. The
sender comparison includes selector, receiver, `uint32` gas limit, and allowlist status. Receiver
configuration first verifies its immutable selector and source chain ID, then compares the current
trusted sender.

## Fund or withdraw LINK

Funding is expressed as a target sender balance, so concurrent deposits or reruns cannot
accidentally double the intended amount:

```shell
NETWORK=mantleSepolia \
TREASURY_ACTION=FUND \
TARGET_LINK_BALANCE=1000000000000000000 \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url mantle_sepolia --broadcast --account funder
```

Withdrawal is expressed as the balance that must remain. In direct mode governance broadcasts the
call. In multisig mode the script creates a Safe proposal:

```shell
NETWORK=mantleSepolia \
TREASURY_ACTION=WITHDRAW \
RETAIN_LINK_BALANCE=500000000000000000 \
TREASURY=0x... \
  forge script script/ManageEtherdocTreasury.s.sol:ManageEtherdocTreasuryScript \
    --rpc-url mantle_sepolia --broadcast --account governance
```

Always choose the retained balance from pending message volume plus a documented safety buffer.

## Verify deployed bytecode

Verification reads the compiler settings, creation transaction, artifact, and constructor arguments
from the immutable deployment manifest:

```shell
NETWORK=mantleSepolia \
RPC_URL="$MANTLE_SEPOLIA_RPC_URL" \
  bash script/verify-contract.sh sender
```

`VERIFIER` defaults to `etherscan`; `VERIFIER_URL` and `ETHERSCAN_API_KEY` may override provider
configuration. Set `VERIFY_DRY_RUN=1` to print the fully assembled command without submitting it.
The command checks the manifest chain ID and live bytecode before calling `forge verify-contract
--watch`.

## Local workflow test

The CI workflow deploys Router and LINK mocks plus both Etherdoc roles to Anvil, reruns every
operation, and asserts that deployer nonce does not move on no-op reruns:

```shell
bash script/test-deployment-workflow.sh
```

It also validates required manifest fields, target-balance funding, retention-based withdrawal, and
verification command construction.
