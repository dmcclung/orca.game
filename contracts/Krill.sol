// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract Krill is ERC20, Ownable {
    // a mapping from an address to whether or not it can mint / burn
    mapping(address => bool) private controllers;

    constructor() ERC20("KRILL", "KRILL") {
        console.log("Deployed Krill");
    }

    /**
     * Mints $KRILL to a controller
     * @param to the controller receiving $KRILL
     * @param amount the amount of $KRILL to mint
     */
    function mint(address to, uint256 amount) external {
        require(controllers[msg.sender], "Only controllers can mint");
        _mint(to, amount);
    }

    /**
     * Burns $KRILL from a holder
     * @param from controller that holds $KRILL
     * @param amount the amount of $KRILL to burn
     */
    function burn(address from, uint256 amount) external {
        require(controllers[msg.sender], "Only controllers can burn");
        _burn(from, amount);
    }

    /**
     * Enables an address to mint / burn
     * @param controller the address to enable
     */
    function addController(address controller) external onlyOwner {
        controllers[controller] = true;
    }

    /**
     * Disables an address from minting / burning
     * @param controller the address to disbale
     */
    function removeController(address controller) external onlyOwner {
        controllers[controller] = false;
    }
}
