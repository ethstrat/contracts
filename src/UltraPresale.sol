// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20MintableBurnable} from "./interfaces/IERC20.sol";
import {ITripwireController} from "./interfaces/ITripwireController.sol";
import {TripwireGuard} from "./lib/TripwireGuard.sol";

/**
 * @title UltraPresale
 * @notice Collects ETH/WETH for the ULTRA presale. Funds are forwarded to the Safe in the same call, never held.
 *         Contributors receive the receipt token 1:1 with wei contributed. No price is set here: after close the
 *         Safe buys the option and converts receipts to ULTRA with a Seaport order at a fixed ratio.
 * @dev Must be granted minter on `receipt` by its owner (the Safe) before `start`. Pause via the tripwire guardian.
 */
contract UltraPresale is TripwireGuard {
    using SafeERC20 for IERC20;

    IERC20MintableBurnable public immutable receipt;
    IERC20 public immutable weth;
    /// @dev Receives every contribution.
    address public immutable safe;
    uint256 public immutable start;
    uint256 public immutable end;
    /// @dev Maximum total contribution in wei.
    uint256 public immutable cap;

    uint256 public totalDeposited;

    event Deposit(address indexed from, address indexed to, uint256 amount, bool isWeth);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidWindow();
    error InvalidCap();
    error NotOpen();
    error CapExceeded(uint256 remaining);
    error EthTransferFailed();

    constructor(
        IERC20MintableBurnable receipt_,
        IERC20 weth_,
        address safe_,
        uint256 start_,
        uint256 end_,
        uint256 cap_,
        ITripwireController controller_,
        address guardian_
    ) TripwireGuard(controller_, guardian_) {
        if (address(receipt_) == address(0) || address(weth_) == address(0) || safe_ == address(0)) {
            revert ZeroAddress();
        }
        if (start_ >= end_ || end_ <= block.timestamp) revert InvalidWindow();
        if (cap_ == 0) revert InvalidCap();
        receipt = receipt_;
        weth = weth_;
        safe = safe_;
        start = start_;
        end = end_;
        cap = cap_;
    }

    /**
     * @notice Contribute native ETH; `to` receives receipt tokens 1:1.
     */
    function deposit(address to) external payable whenNotTripped {
        // Transfer first, record (and its Deposit event) last: the event reflects a fully-settled deposit.
        // `safe` is the trusted multisig, so this ordering is not a CEI/reentrancy concern here.
        (bool success,) = safe.call{value: msg.value}("");
        if (!success) revert EthTransferFailed();
        _record(to, msg.value, false);
    }

    /**
     * @notice Contribute WETH (requires approval to this contract); `to` receives receipt tokens 1:1.
     */
    function depositWeth(address to, uint256 amount) external whenNotTripped {
        weth.safeTransferFrom(msg.sender, safe, amount);
        _record(to, amount, true);
    }

    /// @notice Remaining room under the cap.
    function remaining() external view returns (uint256) {
        return cap - totalDeposited;
    }

    function _record(address to, uint256 amount, bool isWeth) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < start || block.timestamp >= end) revert NotOpen();
        uint256 newTotal = totalDeposited + amount;
        if (newTotal > cap) revert CapExceeded(cap - totalDeposited);
        totalDeposited = newTotal;
        receipt.mint(to, amount);
        emit Deposit(msg.sender, to, amount, isWeth);
    }
}
