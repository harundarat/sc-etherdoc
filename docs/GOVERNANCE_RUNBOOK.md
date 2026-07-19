# Governance and Emergency Pause Runbook

Etherdoc separates slow governance from day-to-day operations. The `owner()` of every production
sender and receiver must be a reviewed multisig contract, not an individual EOA. Operational
accounts never inherit owner permissions.

## Role model

| Principal | Sender permissions | Receiver permissions |
| --- | --- | --- |
| Governance multisig | issuer/role administration, remote config, treasury withdrawal, unpause, two-step ownership transfer | pauser administration, trusted-remote config, unpause, two-step ownership transfer |
| Issuer | register, revoke, or supersede its own records, directly or by EIP-712 signature | none |
| Operator | quote and dispatch configured records | none |
| Pauser | pause registration and/or dispatch | pause receive |
| Relayer | submit a valid issuer-signed operation; no on-chain role is granted | manual CCIP execution follows Chainlink/operator policy |

Issuer removal blocks new registration and supersession but deliberately leaves issuer-authorized
revocation available. An operator cannot change a receiver, authorize an issuer, withdraw funds, or
unpause. A pauser can only move a subsystem into its paused state. Only governance can unpause.

## Deployment checklist

Set distinct addresses when the risk model requires it:

```shell
GOVERNANCE=0x...       # production multisig contract
INITIAL_ISSUER=0x...   # source deployment only
OPERATOR=0x...         # source deployment only
PAUSER=0x...           # source or destination emergency key/multisig
```

The sender constructor receives Router, LINK, governance, initial issuer, initial operator, and
initial pauser. The receiver constructor receives Router, governance, and initial pauser. These
addresses are constructor parameters so the broadcast EOA does not temporarily acquire production
authority.

Before funding or configuring a deployment:

1. Verify deployed bytecode and constructor arguments.
2. Verify `owner()` equals the intended multisig on both chains.
3. Verify initial assignments with `isIssuerAuthorized` and `hasRole`.
4. Verify `registrationPaused`, `dispatchPaused`, and `receivePaused` are false.
5. Execute `configureRemote`, `configureTrustedRemote`, and subsequent role changes through the
   governance multisig. Simulate and review exact calldata before collecting signatures.

The checked-in configure scripts are convenient when the broadcast signer itself is governance,
such as a local environment. Every production network config must set `production: true` and
`governanceMode: "MULTISIG"`. That combination requires the deployed owner to have bytecode and
causes configuration and withdrawal scripts to emit Safe Transaction Builder proposals instead of
broadcasting an EOA transaction. Import, simulate, review, and execute those proposals through the
multisig threshold. The complete command sequence and manifest policy are in
[DEPLOYMENT.md](DEPLOYMENT.md).

## Role rotation

Governance must grant and verify a replacement before revoking the old account:

1. Call `setOperator(newOperator, true)` or `setPauser(newPauser, true)`.
2. Verify the `RoleAuthorizationUpdated` event and `hasRole` result.
3. Exercise the replacement on a controlled operation when practical.
4. Call the corresponding setter for the old account with `false`.
5. Record both transactions and the reason for rotation.

Issuer rotation follows the same grant-before-revoke order with `setIssuerAuthorization`. Historical
records keep their original issuer and are never rewritten by a role change.

Ownership rotation remains two-step:

1. The current multisig calls `transferOwnership(newGovernance)`.
2. Review `OwnershipTransferRequested`.
3. The new multisig calls `acceptOwnership`.
4. Verify `OwnershipTransferred` and `owner()` on-chain.

Operational roles do not move automatically with ownership. Review every issuer, operator, and
pauser assignment separately after governance rotation.

## Emergency pause and recovery

The pauser may independently call `pauseRegistration`, `pauseDispatch`, or `pauseReceive`.

- Registration pause blocks direct and signed registration plus supersession. Revocation stays
  available so an issuer can invalidate compromised documents.
- Dispatch pause blocks new source messages but does not alter prior dispatch records.
- Receive pause makes destination execution revert without a receipt or processed marker. Preserve
  each message ID for retry after recovery.
- Governance configuration and treasury recovery remain available while operational flows are
  paused.

Unpause is a governance-only recovery action. Before unpausing, governance must confirm the root
cause is contained, compromised roles are rotated, remote configuration is correct, pending message
IDs are inventoried, monitoring is active, and the change is linked to an incident record. Resume
receive before dispatch, then manually execute legitimate failed messages using the same message IDs.
The detailed CCIP sequence is in [CCIP_RECOVERY_RUNBOOK.md](CCIP_RECOVERY_RUNBOOK.md).

Etherdoc is intentionally non-upgradeable. If logic changes are required, deploy reviewed contracts
and rotate trusted remotes explicitly. Add a proxy only after upgrade authorization, delay,
monitoring, storage layout, and rollback policy are independently specified.
