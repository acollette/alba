// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ISleeve — minimal strategy-sleeve interface for AlbaVault
/// @notice Sleeves are TRUSTED code: they are added to the vault only by the
/// curator, behind the owner timelock, and hold assets exclusively on behalf of
/// the vault. The vault performs no reentrancy protection against sleeves and
/// believes their accounting — a malicious sleeve is a malicious vault. Keep
/// sleeve implementations tiny and auditable.
interface ISleeve {
    /// @notice Pull `assets` of the vault's underlying token from the caller
    /// (the vault, which approves beforehand) and put them to work.
    function deposit(uint256 assets) external;

    /// @notice Return up to `assets` of the underlying token to the caller.
    /// @dev MUST NOT revert when less than `assets` is instantly available;
    /// return what could actually be sent instead.
    /// @return withdrawn The amount actually transferred back to the caller.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Total underlying value managed by this sleeve, in asset units.
    function totalAssets() external view returns (uint256);

    /// @notice Portion of `totalAssets` withdrawable right now via {withdraw}.
    /// @dev Feeds the vault's maxWithdraw/maxRedeem honesty: never overstate.
    function liquidAssets() external view returns (uint256);

    /// @notice Adapter-type discriminator for UIs/indexers (e.g. "metamorpho",
    /// "midnight") — replaces probing implementation-specific immutables.
    function kind() external pure returns (string memory);
}
