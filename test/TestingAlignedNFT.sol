// SPDX-License-Identifier: VPL
pragma solidity ^0.8.20;

import "../src/AlignedNFT.sol";
import "solady/utils/LibString.sol";

contract TestingAlignedNFT is AlignedNFT {

    using LibString for uint256;

    constructor(
        address _nft,
        address _pushRecipient,
        uint16 _allocation,
        bool _pushStatus
    ) AlignedNFT(_nft, _pushRecipient, _allocation, _pushStatus) { }

    function name() public pure override returns (string memory) { return ("AlignedNFT Test"); }
    function symbol() public pure override returns (string memory) { return ("ANFTTest"); }
    function tokenURI(uint256 _tokenId) public pure override returns (string memory) { return (_tokenId.toString()); }

    function execute_changePushRecipient(address _to) public { _changePushRecipient(_to); }
    function execute_setPushStatus(bool _pushStatus) public { _setPushStatus(_pushStatus); }

    function execute_mint(address _to, uint256 _amount) public payable { _mint(_to, _amount); }
    function execute_withdrawAllocation(address _to, uint256 _amount) public { _withdrawAllocation(_to, _amount); }
}