// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts@5.0.2/token/ERC20/IERC20.sol";

contract ApprovalRestrictedToken is IERC20 {
    uint256 public override totalSupply;
    bool private s_approvalsDisabled;
    bool private s_transfersDisabled;
    mapping(address account => uint256 balance) private s_balances;
    mapping(address owner => mapping(address spender => uint256 amount)) private s_allowances;

    function mint(address _recipient, uint256 _amount) external {
        totalSupply += _amount;
        s_balances[_recipient] += _amount;
        emit Transfer(address(0), _recipient, _amount);
    }

    function setApprovalsDisabled(bool _disabled) external {
        s_approvalsDisabled = _disabled;
    }

    function setTransfersDisabled(bool _disabled) external {
        s_transfersDisabled = _disabled;
    }

    function balanceOf(address _account) external view override returns (uint256) {
        return s_balances[_account];
    }

    function transfer(address _recipient, uint256 _amount) external override returns (bool) {
        if (s_transfersDisabled) {
            return false;
        }
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view override returns (uint256) {
        return s_allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override returns (bool) {
        if (s_approvalsDisabled || (s_allowances[msg.sender][_spender] != 0 && _amount != 0)) {
            return false;
        }
        s_allowances[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override returns (bool) {
        uint256 currentAllowance = s_allowances[_sender][msg.sender];
        if (s_transfersDisabled || currentAllowance < _amount) {
            return false;
        }
        s_allowances[_sender][msg.sender] = currentAllowance - _amount;
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(s_balances[_sender] >= _amount, "insufficient balance");
        s_balances[_sender] -= _amount;
        s_balances[_recipient] += _amount;
        emit Transfer(_sender, _recipient, _amount);
    }
}
