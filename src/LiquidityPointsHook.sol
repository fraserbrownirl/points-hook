// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract LiquidityPointsHook is BaseHook, ERC1155 {
    uint256 public constant POINTS_DIVISOR = 10;
    event PointsMinted(address indexed user, uint256 poolId, uint256 points);

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    /// @notice Mints points to a user based on ETH liquidity added to a pool
    /// @param poolId The ID of the pool
    /// @param hookData Encoded address of the user to receive points
    /// @param points The number of points to mint
    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        if (hookData.length == 0) return;

        address user;
        try this.decodeHookData(hookData) returns (address decoded) {
            user = decoded;
        } catch {
            return;
        }

        if (user != address(0)) {
            uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
            _mint(user, poolIdUint, points, "");
            emit PointsMinted(user, poolIdUint, points);
        }
    }

    /// @notice Helper function to decode hookData safely
    /// @param data The encoded hook data
    /// @return The decoded user address
    function decodeHookData(bytes calldata data) external pure returns (address) {
        return abi.decode(data, (address));
    }

    /// @notice Called after liquidity is added to a pool
    /// @param sender The address that initiated the liquidity addition
    /// @param key The pool key
    /// @param params The liquidity modification parameters
    /// @param delta The balance delta for the liquidity change
    /// @param hookData Additional data passed to the hook
    /// @return selector The function selector
    /// @return delta The balance delta
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (!key.currency0.isAddressZero() || params.liquidityDelta <= 0) {
            return (this.afterAddLiquidity.selector, delta);
        }

        uint256 ethAddedAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForLiquidity = ethAddedAmount / POINTS_DIVISOR;

        if (pointsForLiquidity > 0) {
            _assignPoints(key.toId(), hookData, pointsForLiquidity);
        }

        return (this.afterAddLiquidity.selector, delta);
    }
}
