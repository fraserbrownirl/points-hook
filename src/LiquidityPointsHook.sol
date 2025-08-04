// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @title LiquidityPointsHook
/// @notice A Uniswap V4 hook that rewards liquidity providers with ERC1155 points tokens
/// @dev Points are awarded as 10% of ETH added to pools, with anti-gaming mechanisms
contract LiquidityPointsHook is BaseHook, ERC1155 {
    /// @notice Divisor for points calculation (10% of ETH added)
    uint256 public constant POINTS_DIVISOR = 10;
    
    /// @notice Minimum ETH amount required to earn points (prevents spam)
    uint256 public constant MIN_ETH_FOR_POINTS = 0.001 ether;
    
    /// @notice Cooldown period between point claims per user per pool
    uint256 public constant COOLDOWN_PERIOD = 1 hours;
    
    /// @notice Tracks last points claim timestamp per user per pool
    /// @dev user => poolTokenId => timestamp
    mapping(address => mapping(uint256 => uint256)) public lastPointsClaim;
    
    /// @notice Prevents double-minting within same transaction
    /// @dev transactionHash => processed
    mapping(bytes32 => bool) public processedTransactions;

    /// @notice Emitted when points are successfully minted to a user
    /// @param user Address receiving the points
    /// @param poolTokenId ERC1155 token ID representing the pool
    /// @param points Amount of points minted
    /// @param ethAmount Amount of ETH that generated these points
    /// @param hookData Original hook data for off-chain analysis
    event PointsMinted(
        address indexed user, 
        uint256 indexed poolTokenId, 
        uint256 points, 
        uint256 ethAmount, 
        bytes hookData
    );
    
    /// @notice Emitted when a transaction is processed to prevent double-minting
    /// @param txHash Unique transaction identifier
    /// @param user Address that triggered the transaction
    /// @param poolTokenId Pool token ID involved
    event TransactionProcessed(
        bytes32 indexed txHash, 
        address indexed user, 
        uint256 indexed poolTokenId
    );

    /// @notice Initialize the hook with the pool manager
    /// @param _manager The Uniswap V4 pool manager contract
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    /// @notice Define which hook functions this contract implements
    /// @return permissions Struct defining enabled hook functions
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
                afterAddLiquidity: true,  // Only hook we need
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

    /// @notice ERC1155 metadata URI (placeholder)
    /// @dev In production, this should point to proper metadata
    /// @return URI string for token metadata
    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    /// @notice Generate a unique transaction hash to prevent double-processing
    /// @param sender The sender address
    /// @param poolId The pool ID
    /// @param blockNumber Current block number
    /// @param gasLeft Remaining gas (for uniqueness)
    /// @return txHash Unique transaction identifier
    function _generateTxHash(
        address sender,
        PoolId poolId,
        uint256 blockNumber,
        uint256 gasLeft
    ) internal pure returns (bytes32 txHash) {
        return keccak256(abi.encodePacked(sender, poolId, blockNumber, gasLeft));
    }

    /// @notice Safely extract ETH amount from BalanceDelta using OpenZeppelin SafeCast
    /// @param delta The balance delta from liquidity operation
    /// @param ethIsCurrency0 Whether ETH is currency0 or currency1 in the pool
    /// @return ethAmount The amount of ETH added (0 if none or invalid)
    function _safeGetEthAmount(BalanceDelta delta, bool ethIsCurrency0) internal pure returns (uint256 ethAmount) {
        // Get the raw amount as int128 from the appropriate currency position
        int128 rawAmount = ethIsCurrency0 ? 
            int128(delta.amount0()) : 
            int128(delta.amount1());
        
        // Explicit check: only negative amounts represent user → pool transfers
        if (rawAmount < 0) {
            // Use SafeCast for secure type conversion
            ethAmount = SafeCast.toUint256(SafeCast.toUint128(-rawAmount));
        } else {
            // If amount is 0 or positive, no ETH was actually deposited
            ethAmount = 0;
        }
    }

    /// @notice Mints points to the liquidity provider with comprehensive safety checks
    /// @param poolId The ID of the pool
    /// @param sender The address that added the liquidity
    /// @param ethAmount The amount of ETH added
    /// @param hookData The original hook data for logging purposes
    function _assignPointsToSender(
        PoolId poolId,
        address sender,
        uint256 ethAmount,
        bytes calldata hookData
    ) internal {
        // Early returns for invalid conditions (gas efficient)
        if (sender == address(0) || ethAmount < MIN_ETH_FOR_POINTS) {
            return;
        }

        // Use direct PoolId → tokenId conversion (simple and decentralized)
        uint256 poolTokenId = uint256(PoolId.unwrap(poolId));

        // Anti-gaming: Check cooldown period
        if (block.timestamp < lastPointsClaim[sender][poolTokenId] + COOLDOWN_PERIOD) {
            return;
        }

        // Prevent double-minting for the same transaction
        bytes32 txHash = _generateTxHash(sender, poolId, block.number, gasleft());
        if (processedTransactions[txHash]) {
            return;
        }

        // Calculate points (10% of ETH added)
        uint256 pointsToMint = ethAmount / POINTS_DIVISOR;
        
        if (pointsToMint > 0) {
            // Update state before external calls (CEI pattern)
            lastPointsClaim[sender][poolTokenId] = block.timestamp;
            processedTransactions[txHash] = true;
            
            // Mint points to the user
            _mint(sender, poolTokenId, pointsToMint, "");
            
            // Emit events for monitoring and off-chain analysis
            emit PointsMinted(sender, poolTokenId, pointsToMint, ethAmount, hookData);
            emit TransactionProcessed(txHash, sender, poolTokenId);
        }
    }

    /// @notice Hook function called after liquidity is added to a pool
    /// @param sender The address that initiated the liquidity addition
    /// @param key The pool key containing currency and fee information
    /// @param params The liquidity modification parameters
    /// @param delta The balance delta showing token amounts transferred
    /// @param hookData Additional data passed to the hook (logged but not used for security)
    /// @return selector The function selector to confirm successful execution
    /// @return delta The unmodified balance delta
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        // Check if this pool contains the native token (ETH) in either position
        bool ethIsCurrency0 = key.currency0.isAddressZero();
        bool ethIsCurrency1 = key.currency1.isAddressZero();
        bool hasNativeToken = ethIsCurrency0 || ethIsCurrency1;
        
        // Only proceed if pool has native token and liquidity was added
        if (!hasNativeToken || params.liquidityDelta <= 0) {
            return (this.afterAddLiquidity.selector, delta);
        }

        // Safely extract ETH amount from delta
        uint256 ethAddedAmount = _safeGetEthAmount(delta, ethIsCurrency0);
        
        // Only award points if actual ETH was deposited
        if (ethAddedAmount > 0) {
            _assignPointsToSender(key.toId(), sender, ethAddedAmount, hookData);
        }

        return (this.afterAddLiquidity.selector, delta);
    }

    /// @notice Check if a user is in cooldown period for a specific pool
    /// @param user The user address to check
    /// @param poolId The pool ID to check
    /// @return inCooldown Whether the user is currently in cooldown
    /// @return remainingTime Remaining cooldown time in seconds (0 if not in cooldown)
    function getCooldownStatus(address user, PoolId poolId) 
        external 
        view 
        returns (bool inCooldown, uint256 remainingTime) 
    {
        uint256 poolTokenId = uint256(PoolId.unwrap(poolId));
        uint256 lastClaim = lastPointsClaim[user][poolTokenId];
        uint256 cooldownEnd = lastClaim + COOLDOWN_PERIOD;
        
        if (block.timestamp >= cooldownEnd) {
            return (false, 0);
        } else {
            return (true, cooldownEnd - block.timestamp);
        }
    }

    /// @notice Get the points balance for a user in a specific pool
    /// @param user The user address to query
    /// @param poolId The pool ID to query
    /// @return balance The user's points balance for this pool
    function getPointsBalance(address user, PoolId poolId) 
        external 
        view 
        returns (uint256 balance) 
    {
        uint256 poolTokenId = uint256(PoolId.unwrap(poolId));
        return balanceOf(user, poolTokenId);
    }

    /// @notice Get total points supply for a specific pool
    /// @param poolId The pool ID to query
    /// @return totalSupply Total points minted for this pool
    function getPoolPointsSupply(PoolId poolId) 
        external 
        view 
        returns (uint256 totalSupply) 
    {
        uint256 poolTokenId = uint256(PoolId.unwrap(poolId));
        return totalSupply(poolTokenId);
    }
}
