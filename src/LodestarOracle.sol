// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFtsoV2} from "./interfaces/IFtsoV2.sol";
import {ILstRateProvider} from "./interfaces/ILstRateProvider.sol";

/// @title LodestarOracle
/// @notice USD valuation of collateral using Flare's enshrined FTSOv2 oracle.
/// @dev For direct feeds (FXRP -> XRP/USD) set rateProvider = address(0).
///      For LSTs (sFLR) set a feed on the underlying (FLR/USD) plus an sFLR->FLR rate provider.
contract LodestarOracle is Ownable {
    struct Feed {
        bytes21 feedId; // FTSO feed id of the underlying asset (USD-denominated)
        address rateProvider; // optional: share->underlying rate (0 for 1:1 assets)
        uint8 tokenDecimals; // ERC20 decimals of the collateral token
        uint64 maxStale; // max age (seconds) of an FTSO update; 0 = no check
        bool set;
    }

    IFtsoV2 public immutable ftso;
    mapping(address => Feed) public feeds;

    event FeedSet(address indexed token, bytes21 feedId, address rateProvider, uint64 maxStale);

    error FeedNotSet();
    error StalePrice();
    error BadPrice();

    constructor(address _ftso, address _owner) Ownable(_owner) {
        ftso = IFtsoV2(_ftso);
    }

    function setFeed(address token, bytes21 feedId, address rateProvider, uint64 maxStale) external onlyOwner {
        feeds[token] = Feed(feedId, rateProvider, IERC20Metadata(token).decimals(), maxStale, true);
        emit FeedSet(token, feedId, rateProvider, maxStale);
    }

    /// @notice USD price of one whole token, scaled to 1e18.
    function priceUsd18(address token) public view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.set) revert FeedNotSet();
        (uint256 value, int8 dec, uint64 ts) = ftso.getFeedById(f.feedId);
        if (value == 0) revert BadPrice();
        if (f.maxStale != 0 && block.timestamp > uint256(ts) + f.maxStale) revert StalePrice();

        uint256 price18 = _to18(value, dec);
        if (f.rateProvider != address(0)) {
            uint256 rate = ILstRateProvider(f.rateProvider).underlyingPerShare(); // 1e18
            if (rate == 0) revert BadPrice();
            price18 = (price18 * rate) / 1e18;
        }
        return price18;
    }

    /// @notice USD value (1e18) of `amount` raw units of `token`.
    function usdValue18(address token, uint256 amount) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.set) revert FeedNotSet();
        uint256 p = priceUsd18(token);
        return (p * amount) / (10 ** f.tokenDecimals);
    }

    /// @notice Current share->underlying rate of `token` (1e18-scaled); 1e18 if it has no LST rate.
    /// @dev Used by the loan book to measure staking appreciation between open and repay.
    function rateOf(address token) external view returns (uint256) {
        address rp = feeds[token].rateProvider;
        return rp == address(0) ? 1e18 : ILstRateProvider(rp).underlyingPerShare();
    }

    function _to18(uint256 value, int8 dec) internal pure returns (uint256) {
        int256 diff = int256(18) - int256(dec);
        if (diff >= 0) return value * (10 ** uint256(diff));
        return value / (10 ** uint256(-diff));
    }
}
