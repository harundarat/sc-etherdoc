// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

/**
 * @notice Shared two-step governance and narrowly scoped operational roles.
 * @dev The owner should be a production multisig. Operational roles do not inherit owner powers.
 */
abstract contract EtherdocGovernance is ConfirmedOwner {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    error InvalidGovernanceAddress();
    error InvalidRoleAccount();
    error UnauthorizedRole(bytes32 role, address account);

    event RoleAuthorizationUpdated(bytes32 indexed role, address indexed account, bool authorized);

    mapping(bytes32 role => mapping(address account => bool authorized)) private s_roles;

    constructor(address _governance) ConfirmedOwner(_validateGovernance(_governance)) {}

    modifier onlyRole(bytes32 _role) {
        if (!s_roles[_role][msg.sender]) {
            revert UnauthorizedRole(_role, msg.sender);
        }
        _;
    }

    function hasRole(bytes32 _role, address _account) external view returns (bool) {
        return s_roles[_role][_account];
    }

    function _setRole(bytes32 _role, address _account, bool _authorized) internal {
        if (_account == address(0)) {
            revert InvalidRoleAccount();
        }
        s_roles[_role][_account] = _authorized;
        emit RoleAuthorizationUpdated(_role, _account, _authorized);
    }

    function _validateGovernance(address _governance) private pure returns (address) {
        if (_governance == address(0)) {
            revert InvalidGovernanceAddress();
        }
        return _governance;
    }
}
