// SPDX-License-Identifier: VPL
pragma solidity ^0.8.20;

import "solady/tokens/ERC721.sol";
import "solady/utils/FixedPointMathLib.sol";
import "openzeppelin/interfaces/IERC20.sol";
import "openzeppelin/interfaces/IERC721.sol";
import "v2-core/interfaces/IUniswapV2Pair.sol";
import "v2-periphery/interfaces/IUniswapV2Router02.sol";
import "./UniswapAdd.sol";
import "./UniswapV2LiquidityHelper.sol";
import "./xTokenLocker.sol";

interface INFTXVault {
    function mint(uint256[] calldata tokenIds, uint256[] calldata amounts) external;
}

abstract contract AlignedWithRemilia is ERC721 {

    error Initialized();
    error NotInitialized();
    error NotAligned();
    error SwapFailed();
    error MintFailed();
    error LiquidityFailed();
    error StakeFailed();
    error TransferFailed();
    error ClaimFailed();
    error WithdrawFailed();
    error Overdraft();
    error NotOwner();
    error BadAddress();

    event DevAllocation(uint256 indexed _devAllocation);
    event DevWithdraw(uint256 indexed _amount);
    event Tithe(address indexed _sender, uint256 indexed _amount);
    event MILADYPurchased(uint256 indexed _ethAmount, uint256 indexed _miladyAmount);
    event MILADYWETHAdded(uint256 indexed _ethAmount, uint256 indexed _miladyAmount);
    event MILADYWETHStaked(uint256 indexed _amount);

    // Addresses for all related contracts
    IERC721 constant internal _miladyNFT = IERC721(0x5Af0D9827E0c53E4799BB226655A1de152A425a5);
    IERC20 constant internal _nftx_MILADY = IERC20(0x227c7DF69D3ed1ae7574A1a7685fDEd90292EB48);
    IERC20 constant internal _nftx_xMILADY = IERC20(0x5D1C5Dee420004767d3e2fb7AA7C75AA92c33117);
    IUniswapV2Pair constant internal _nftx_MILADYWETH = IUniswapV2Pair(0x15A8E38942F9e353BEc8812763fb3C104c89eCf4);
    IERC20 constant internal _nftx_xMILADYWETH = IERC20(0x6c6BCe43323f6941FD6febe8ff3208436e8e0Dc7);
    IUniswapV2Router02 internal _router = IUniswapV2Router02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    INFTXVault constant internal _nftxNFTStaking = INFTXVault(0x227c7DF69D3ed1ae7574A1a7685fDEd90292EB48);
    INFTXLPStaking internal _nftxLPStaking = INFTXLPStaking(0x688c3E4658B5367da06fd629E41879beaB538E37);
    xTokenLocker internal immutable _xTokenVault;
    UniswapV2LiquidityHelper internal immutable _liqHelper;
    address internal _sushiV2Factory = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address constant internal _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    bool internal _alignmentInitialized; // Minting won't function until initialized
    address internal _devAddress; // Dev's address
    uint256 public devAllocation; // Percentage (0.0% to 50.0%) of dev's cut

    mapping(address => uint256) public tithes; // Tithes per user
    mapping(address => uint256) public instantTithes; // Instant tithes to locked liquidity per user
    uint256 public titheTotal; // Total collected tithes
    uint256 public pooledTithes; // Current balance of ETH tithes
    uint256 public devBalance; // Current dev balance

    constructor() payable {
        _xTokenVault = new xTokenLocker();
        _liqHelper = new UniswapV2LiquidityHelper(_sushiV2Factory, address(_router), _WETH);
    }

    // Check Milady NFT balance
    function checkBalanceMiladyNFT() public view returns (uint256) { return (_miladyNFT.balanceOf(address(this))); }
    // Check MILADY balance
    function checkBalanceMILADY() public view returns (uint256) { return (_nftx_MILADY.balanceOf(address(this))); }
    // Check xMILADY balance
    function checkBalancexMILADY() public view returns (uint256) { return (_nftx_xMILADY.balanceOf(address(this))); }
    // Check MILADYWETH balance
    function checkBalanceMILADYWETH() public view returns (uint256) { return (_nftx_MILADYWETH.balanceOf(address(this))); }
    // Check xMILADYWETH balance
    function checkBalancexMILADYWETH() public view returns (uint256) { return (_nftx_xMILADYWETH.balanceOf(address(this))); }

    // Initialization function used to set dev's cut percentage (up to 50.0%)
    function _initializeAlignment(address _address, uint256 _devAllocation) internal {
        if (_alignmentInitialized) { revert Initialized(); }
        if (_devAllocation > 500) { revert NotAligned(); }
        _devAddress = _address;
        devAllocation = _devAllocation;
        _alignmentInitialized = true;
        emit DevAllocation(_devAllocation);
    }

    // Change router address
    function _changeRouter(address _newRouter) internal {
        if (_newRouter == address(0)) { revert BadAddress(); }
        _router = IUniswapV2Router02(_newRouter);
    }
    // Change factory address
    function _changeFactory(address _newFactory) internal {
        if (_newFactory == address(0)) { revert BadAddress(); }
        _sushiV2Factory = _newFactory;
    }
    // Change NFTX LP Staking contract address
    function _changeNFTXLPStaking(address _address) internal {
        if (_address == address(0)) { revert BadAddress(); }
        _nftxLPStaking = INFTXLPStaking(_address);
        _xTokenVault.changeNFTXLPStakingContract(_address);
    }
    // Change dev's address
    function _changeDevAddress(address _newAddress) internal {
        if (_newAddress == address(0)) { revert BadAddress(); }
        _devAddress = _newAddress;
    }
    // Change dev allocation, cannot be set above 50.0%
    function _changeDevAllocation(uint256 _devAllocation) internal {
        if (_devAllocation > 500) { revert NotAligned(); }
        devAllocation = _devAllocation;
        emit DevAllocation(_devAllocation);
    }

    // Swaps ETH to MILADY NFTX token
    function _swapETHtoMILADY(uint256 _amount) internal returns (uint256) {
        // Confirm _amount isn't above pooledTithes
        if (_amount > pooledTithes) { revert Overdraft(); }
        // Reduce pooled tithes by _amount
        pooledTithes -= _amount;

        // Prepare SushiSwap router path
        address[] memory path = new address[](2);
        path[0] = _router.WETH();
        path[1] = address(_nftx_MILADY);

        // Retrieve MILADY balance
        uint256 miladyBal = checkBalanceMILADY();
        // Swap _amount for MILADY
        _router.swapExactETHForTokens{value: _amount}(0, path, address(this), block.timestamp + 1);
        // Retrieve swapped MILADY quantity
        uint256 miladyNewBal = checkBalanceMILADY() - miladyBal;
        // Check that balance > 0 to ensure swap was successful
        if (miladyNewBal == 0) { revert SwapFailed(); }

        // Return amount of MILADY tokens received
        emit MILADYPurchased(_amount, miladyNewBal);
        return (miladyNewBal);
    }
    // TODO: Swaps MILADY to ETH
    function _swapMILADYtoETH(uint256 _amount) internal returns (uint256) {
        // Confirm contract holds _amount minimum
        if (_amount > checkBalanceMILADY()) { revert Overdraft(); }

        // Prepare SushiSwap router path
        address[] memory path = new address[](2);
        path[0] = _router.WETH();
        path[1] = address(_nftx_MILADY);

        // Approve Uniswap router to spend the tokens
        _nftx_MILADY.approve(address(_router), _amount);
        // Check contract's ETH balance
        uint256 ethBal = address(this).balance;

        // Make the swap
        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(_amount, 0, path, msg.sender, block.timestamp);
        // Calculate difference
        uint256 ethDiff = ethBal - address(this).balance;

        // Verify swap completed for non-zero amount
        if (ethDiff == 0) { revert SwapFailed(); }
        // Update pooled tithe balance
        pooledTithes += ethDiff;

        // Return ETH swap amount
        return (ethDiff);
    }

    // Add MILADY/WETH liquidity
    function _addLiquidityMILADYWETH(uint256 _ethAmount, uint256 _miladyAmount) internal returns (uint256) {
        // Confirm amounts arent above balances
        if (_ethAmount > pooledTithes) { revert Overdraft(); }
        if (_miladyAmount > checkBalanceMILADY()) { revert Overdraft(); }

        // Retrieve current MILADYWETH balance
        uint256 miladywethBal = checkBalanceMILADYWETH();

        /*
        // Approve SushiSwap router to use MILADY
        _nftx_MILADY.approve(address(_router), _miladyAmount);
        // Add MILADY and ETH to MILADY/WETH liquidity pool
        _router.addLiquidityETH{value: _ethAmount}(address(_nftx_MILADY), _miladyAmount, 0, 0, address(this), block.timestamp + 1);
        */
        // Use gas-efficient UniswapAdd contract to add liquidity
        // TODO: Investigate effects of eventual selfdestruct() deprecation as it is used here
        new UniswapAdd{ value: _ethAmount }(address(_nftx_MILADY));

        // Check updated MILADYWETH balance
        uint256 miladywethNewBal = checkBalanceMILADYWETH() - miladywethBal;
        // Confirm balance increased
        if (miladywethNewBal == 0) { revert LiquidityFailed(); }

        // Return amount of MILADY/WETH LP tokens received
        emit MILADYWETHAdded(_ethAmount, _miladyAmount);
        return (miladywethNewBal);
    }

    // TODO: Add as much MILADY/WETH liquidity as possible
    function _addMaximumLiquidityMILADYWETH() internal returns (uint256) {
        // Retrieve MILADYWETH balance
        uint256 miladywethBal = checkBalanceMILADYWETH();

        // Use UniswapV2LiquidityHelper contract to perform swaps and add liquidity
        _liqHelper.swapAndAddLiquidityEthAndToken{ value: pooledTithes }(
            address(_nftx_MILADY), uint112(checkBalanceMILADY()), 1, address(this));

        // Calculate difference in MILADYWETH
        uint256 miladywethDiff = checkBalanceMILADYWETH() - miladywethBal;
        // If no increase, revert as liquidity addition failed
        if (miladywethDiff == 0) { revert LiquidityFailed(); }
        
        // Return MILADYWETH diff
        return (miladywethDiff);
    }

    // Stakes MILADYWETH in the NFTX LP staking contract
    function _stakeMILADYWETH(uint256 _amount) internal returns (uint256) {
        // Confirm amounts arent above balances
        if (_amount > checkBalanceMILADYWETH()) { revert Overdraft(); }
        // Check existing xMILADYWETH balance
        uint256 xmiladywethBal = checkBalancexMILADYWETH();

        // Stake MILADYWETH in NFTX LP staking contract
        _nftxLPStaking.deposit(392, _amount);

        // Confirm xMILADYWETH balance increased
        uint256 xmiladywethNewBal = checkBalancexMILADYWETH() - xmiladywethBal;
        if (xmiladywethNewBal == 0) { revert StakeFailed(); }

        emit MILADYWETHStaked(_amount);
        return (xmiladywethNewBal);
    }

    // Permanently lock xMILADYWETH by sending it to _xTokenVault
    function _lockxMILADYWETH(uint256 _amount) internal {
        // Confirm _amount is owned by contract
        if (_amount > checkBalancexMILADYWETH()) { revert Overdraft(); }
        bool success = _nftx_xMILADYWETH.transfer(address(_xTokenVault), _amount);
        if (!success) { revert TransferFailed(); }
    }

    // Converts ETH to MILADYWETH LP and stakes it
    function _swapStakeLockMILADYWETH(uint256 _amount) internal {
        // Confirm _amount isn't above pooledTithes
        if (_amount > pooledTithes) { revert Overdraft(); }

        // Round tithe amount evenly as we need to split it in two
        uint256 amount = (_amount % 2 == 1) ? _amount - 1 : _amount;
        // Calculate half of msg.value
        uint256 ethHalf = amount / 2;

        // Convert half of msg.value to MILADY
        uint256 miladyTokens = _swapETHtoMILADY(ethHalf);

        // Add MILADY and remaining half of msg.value to MILADY/WETH LP
        uint256 miladyLiquidity = _addLiquidityMILADYWETH(ethHalf, miladyTokens);

        // Stake MILADY/WETH LP tokens
        uint256 miladyLiqStaked = _stakeMILADYWETH(miladyLiquidity);

        // Permanently lock xMILADYWETH
        _lockxMILADYWETH(miladyLiqStaked);
    }

    // TODO: Purchase a floor Milady with pooled tithes
    function _purchaseFloorMiladyNFT() internal {
        // Step 1) Get Milady floor price from Blur
        // Step 2) Confirm pooledTithes balance is at or above floor price
        // Step 3) Execute buy
        // Step 4) Confirm NFT received
        // Step 5) Correct pooledTithes balance
    }
    // TODO: Purchase a floor Milady of a specific trait
    function _purchaseTraitFloorMiladyNFT() internal {
        // Same as _purchaseFloorMiladyNFT just with trait specification included
    }
    // TODO: Purchase a specific Milady
    function _purchaseSpecificMiladyNFT(uint256 _tokenId) internal {
        // Same as _purchaseFloorMiladyNFT just focused on a specific tokenId
    }

    // TODO: Stake Milady NFTs for MILADY
    function _stakeMiladyNFT(uint256[] memory _tokenIds) internal {
        // Retrieve current MILADY balance
        uint256 miladyBal = checkBalanceMILADY();
        // Prep amounts array
        uint256[] memory amounts = new uint256[](_tokenIds.length);

        // Set approval for all NFTs
        _miladyNFT.setApprovalForAll(address(_nftxNFTStaking), true);

        // Confirm contract owns all NFTs
        for (uint i; i < _tokenIds.length;) {
            if (_miladyNFT.ownerOf(_tokenIds[i]) != address(this)) { revert NotOwner(); }
            amounts[i] = 1;
            unchecked { ++i; }
        }

        // Mint all NFTs into MILADY
        _nftxNFTStaking.mint(_tokenIds, amounts);
        // Check to ensure all NFTs were minted into MILADY tokens
        uint256 miladyDiff = checkBalanceMILADY() - miladyBal;
        if (miladyDiff == 0) { revert MintFailed(); }
    }

    // Mint function handles separation of dev and ministry funds
    // Also allows for users to decide if they pool their tithe or instantly convert it to Milady liquidity
    function _mint(address _to, uint256 _tokenId, bool _poolTithe) internal {
        // Revert if initialization hasn't taken place
        if (!_alignmentInitialized) { revert NotInitialized(); }

        // Calculate tithe after dev's cut
        uint256 devsCut = FixedPointMathLib.fullMulDiv(devAllocation, msg.value, 1000);
        devBalance += devsCut;
        uint256 tithe = msg.value - devsCut;

        // Tally tithe amount
        tithes[msg.sender] += tithe;
        titheTotal += tithe;
        pooledTithes += tithe;

        // If tithe isn't being pooled, process it immediately
        if (_poolTithe == false) {
            _swapStakeLockMILADYWETH(tithe);
        }
        emit Tithe(msg.sender, tithe);

        // Process solady ERC721 mint logic
        super._mint(_to, _tokenId);
    }

    // Process withdrawal of dev balance to _dev address
    function _devWithdraw(uint256 _amount) internal {
        // Ensure amount doesn't exceed dev's balance
        if (_amount > devBalance) { revert Overdraft(); }
        // Deduct amount from balance before transfer to prevent reentrancy
        devBalance -= _amount;
        // Confirm withdrawal was successful, revert if not
        (bool success, ) = payable(_devAddress).call{ value: _amount }("");
        if (!success) { revert WithdrawFailed(); }
        emit DevWithdraw(_amount);
    }

    // Claim rewards accrued from xMILADYWETH
    function _claimRewards() internal {
        // Retrieve current MILADY balance
        uint256 miladyBal = checkBalanceMILADY();

        // If dev's cut is <=20% then they get liquidity rewards
        if (devAllocation <= 200) {
            _xTokenVault.claimRewards();
            uint256 miladyDiff = checkBalanceMILADY() - miladyBal;
            bool success = _nftx_MILADY.transfer(_devAddress, miladyDiff);
            if (!success) { revert ClaimFailed(); }
        } else { // If the dev wants more, the rewards go to Milady
            _xTokenVault.claimRewards();
        }
    }

    // Add all ETH directly sent to contract to the tithe pool
    receive() external virtual payable {
        tithes[msg.sender] += msg.value;
        titheTotal += msg.value;
        pooledTithes += msg.value;
        emit Tithe(msg.sender, msg.value);
    }
    fallback() external virtual payable {
        tithes[msg.sender] += msg.value;
        titheTotal += msg.value;
        pooledTithes += msg.value;
        emit Tithe(msg.sender, msg.value);
    }
}