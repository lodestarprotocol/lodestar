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
        uint64 maxStale; // max age (seconds) of an FTSO update; mandatory, bounded to <= 1h
        uint16 haircutBps; // conservative discount on the reported value (0 = none, max 5000)
        bool set;
    }

    IFtsoV2 public immutable ftso;
    mapping(address => Feed) public feeds;

    event FeedSet(address indexed token, bytes21 feedId, address rateProvider, uint64 maxStale, uint16 haircutBps);

    error FeedNotSet();
    error StalePrice();
    error BadPrice();
    error BadParam();

    constructor(address _ftso, address _owner) Ownable(_owner) {
        ftso = IFtsoV2(_ftso);
    }

    /// @param maxStale max age (seconds) of an FTSO update; mandatory and bounded to <= 1 hour.
    /// @param haircutBps conservative discount applied to every reported value (<= 5000). Zero for
    ///        a 1:1-backed asset (FXRP≈XRP); non-zero for a wrapper that can trade under its
    ///        underlying (an LST under NAV), so LTV, the settlement floor, and impairment all use
    ///        realizable value, not par.
    function setFeed(address token, bytes21 feedId, address rateProvider, uint64 maxStale, uint16 haircutBps)
        external
        onlyOwner
    {
        // A staleness bound is mandatory: borrowing against a stale-high price is the one oracle
        // attack a lagged-but-live feed permits. FTSO updates every ~90s, so an hour is already
        // generous; anything longer has no legitimate use and is a crash-window over-borrow risk.
        if (maxStale == 0 || maxStale > 1 hours) revert BadParam();
        if (haircutBps > 5000) revert BadParam();
        feeds[token] = Feed(feedId, rateProvider, IERC20Metadata(token).decimals(), maxStale, haircutBps, true);
        emit FeedSet(token, feedId, rateProvider, maxStale, haircutBps);
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
        // Apply the conservative haircut so every downstream risk decision (LTV, settlement
        // floor, impairment) uses realizable value rather than par for wrappers that can trade
        // under their underlying.
        if (f.haircutBps != 0) price18 = (price18 * (10_000 - f.haircutBps)) / 10_000;
        // Guard the *scaled* price, not just the raw feed value: a feed whose decimals exceed
        // 18 enough to floor to zero would otherwise pass as a legitimate (mispriced) zero.
        if (price18 == 0) revert BadPrice();
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
