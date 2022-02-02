// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Krill.sol";
import "./Orca.sol";

contract Berg is Ownable, IERC721Receiver, Pausable {
  
  // maximum alpha score for a Wolf
  uint8 public constant MAX_ALPHA = 8;

  // struct to store a stake's token, owner, and earning values
  struct Stake {
    uint16 tokenId;
    uint80 value;
    address owner;
  }

  event TokenStaked(address owner, uint256 tokenId, uint256 value);
  event PenguinClaimed(uint256 tokenId, uint256 earned, bool unstaked);
  event OrcaClaimed(uint256 tokenId, uint256 earned, bool unstaked);

  // reference to the Orca NFT contract
  Orca private orca;
  // reference to the $Krill contract for minting $Krill earnings
  Krill private krill;

  // maps tokenId to stake
  mapping(uint256 => Stake) public berg; 
  // maps alpha to all Wolf stakes with that alpha
  mapping(uint256 => Stake[]) public pack; 
  // tracks location of each Wolf in Pack
  mapping(uint256 => uint256) public packIndices; 
  // total alpha scores staked
  uint256 public totalAlphaStaked = 0; 
  // any rewards distributed when no wolves are staked
  uint256 public unaccountedRewards = 0; 
  // amount of $Krill due for each alpha point staked
  uint256 public krillPerAlpha = 0; 

  // penguins earn 10000 $Krill per day
  uint256 public constant DAILY_KRILL_RATE = 10000 ether;
  // sheep must have 2 days worth of $Krill to unstake or else it's too cold
  uint256 public constant MINIMUM_TO_EXIT = 2 days;
  // wolves take a 20% tax on all $Krill claimed
  uint256 public constant KRILL_CLAIM_TAX_PERCENTAGE = 20;
  // there will only ever be (roughly) 2.4 billion $Krill earned through staking
  uint256 public constant MAXIMUM_GLOBAL_KRILL = 2400000000 ether;

  // amount of $Krill earned so far
  uint256 public totalKrillEarned;
  // number of Penguins staked in the berg
  uint256 public totalPenguinsStaked;
  // the last time $Krill was claimed
  uint256 public lastClaimTimestamp;

  // emergency rescue to allow unstaking without any checks but without $Krill
  bool public rescueEnabled = false;

  /**
   * @param _orca reference to the Orca NFT contract
   * @param _krill reference to the $Krill token
   */
  constructor(address _orca, address _krill) { 
    orca = Orca(_orca);
    krill = Krill(_krill);
  }

  /** STAKING */

  /**
   * adds Penguin and Orca to the Berg and Pack
   * @param account the address of the staker
   * @param tokenIds the IDs of the Penguins and Orca to stake
   */
  function addManyToBergAndPack(address account, uint16[] calldata tokenIds) external {
    require(account == _msgSender() || _msgSender() == address(orca), "DONT GIVE YOUR TOKENS AWAY");
    for (uint i = 0; i < tokenIds.length; i++) {
      if (_msgSender() != address(orca)) { // dont do this step if its a mint + stake
        require(orca.ownerOf(tokenIds[i]) == _msgSender(), "AINT YO TOKEN");
        orca.transferFrom(_msgSender(), address(this), tokenIds[i]);
      } else if (tokenIds[i] == 0) {
        continue; // there may be gaps in the array for stolen tokens
      }

      if (isPenguin(tokenIds[i])) 
        _addPenguinToBerg(account, tokenIds[i]);
      else 
        _addOrcaToPack(account, tokenIds[i]);
    }
  }

  /**
   * adds a single Penguin to the Berg
   * @param account the address of the staker
   * @param tokenId the ID of the Penguin to add to the Berg
   */
  function _addPenguinToBerg(address account, uint256 tokenId) internal whenNotPaused _updateEarnings {
    berg[tokenId] = Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(block.timestamp)
    });
    totalPenguinsStaked += 1;
    emit TokenStaked(account, tokenId, block.timestamp);
  }

  /**
   * adds a single Orca to the Pack
   * @param account the address of the staker
   * @param tokenId the ID of the Orca to add to the Pack
   */
  function _addOrcaToPack(address account, uint256 tokenId) internal {
    uint256 alpha = _alphaForOrca(tokenId);
    totalAlphaStaked += alpha; // Portion of earnings ranges from 8 to 5
    packIndices[tokenId] = pack[alpha].length; // Store the location of the orca in the Pack
    pack[alpha].push(Stake({
      owner: account,
      tokenId: uint16(tokenId),
      value: uint80(krillPerAlpha)
    })); // Add the wolf to the Pack
    emit TokenStaked(account, tokenId, krillPerAlpha);
  }

  /** CLAIMING / UNSTAKING */

  /**
   * realize $Krill earnings and optionally unstake tokens from the Berg / Pack
   * to unstake a Penguin it will require it has 2 days worth of $Krill unclaimed
   * @param tokenIds the IDs of the tokens to claim earnings from
   * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
   */
  function claimManyFromBergAndPack(uint16[] calldata tokenIds, bool unstake) external whenNotPaused _updateEarnings {
    uint256 owed = 0;
    for (uint i = 0; i < tokenIds.length; i++) {
      if (isPenguin(tokenIds[i]))
        owed += _claimPenguinsFromBerg(tokenIds[i], unstake);
      else
        owed += _claimOrcaFromPack(tokenIds[i], unstake);
    }
    if (owed == 0) return;
    krill.mint(_msgSender(), owed);
  }

  /**
   * realize $Krill earnings for a single Penguin and optionally unstake it
   * if not unstaking, pay a 20% tax to the staked Orcas
   * if unstaking, there is a 50% chance all $Krill is stolen
   * @param tokenId the ID of the Penguin to claim earnings from
   * @param unstake whether or not to unstake the Penguin
   * @return owed - the amount of $Krill earned
   */
  function _claimPenguinsFromBerg(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    Stake memory stake = berg[tokenId];
    require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
    require(!(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT), "GONNA BE COLD WITHOUT TWO DAY'S Krill");
    if (totalKrillEarned < MAXIMUM_GLOBAL_KRILL) {
      owed = (block.timestamp - stake.value) * DAILY_KRILL_RATE / 1 days;
    } else if (stake.value > lastClaimTimestamp) {
      owed = 0; // $Krill production stopped already
    } else {
      owed = (lastClaimTimestamp - stake.value) * DAILY_KRILL_RATE / 1 days; // stop earning additional $Krill if it's all been earned
    }
    if (unstake) {
      if (random(tokenId) & 1 == 1) { // 50% chance of all $Krill stolen
        _payOrcaTax(owed);
        owed = 0;
      }
      orca.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Sheep
      delete berg[tokenId];
      totalPenguinsStaked -= 1;
    } else {
      _payOrcaTax(owed * KRILL_CLAIM_TAX_PERCENTAGE / 100); // percentage tax to staked wolves
      owed = owed * (100 - KRILL_CLAIM_TAX_PERCENTAGE) / 100; // remainder goes to Sheep owner
      berg[tokenId] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(block.timestamp)
      }); // reset stake
    }
    emit PenguinClaimed(tokenId, owed, unstake);
  }

  /**
   * realize $Krill earnings for a single Orca and optionally unstake it
   * Orcas earn $Krill proportional to their Alpha rank
   * @param tokenId the ID of the Orca to claim earnings from
   * @param unstake whether or not to unstake the Orca
   * @return owed - the amount of $Krill earned
   */
  function _claimOrcaFromPack(uint256 tokenId, bool unstake) internal returns (uint256 owed) {
    require(orca.ownerOf(tokenId) == address(this), "AINT A PART OF THE PACK");
    uint256 alpha = _alphaForOrca(tokenId);
    Stake memory stake = pack[alpha][packIndices[tokenId]];
    require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
    owed = (alpha) * (krillPerAlpha - stake.value); // Calculate portion of tokens based on Alpha
    if (unstake) {
      totalAlphaStaked -= alpha; // Remove Alpha from total staked
      orca.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Wolf
      Stake memory lastStake = pack[alpha][pack[alpha].length - 1];
      pack[alpha][packIndices[tokenId]] = lastStake; // Shuffle last Wolf to current position
      packIndices[lastStake.tokenId] = packIndices[tokenId];
      pack[alpha].pop(); // Remove duplicate
      delete packIndices[tokenId]; // Delete old mapping
    } else {
      pack[alpha][packIndices[tokenId]] = Stake({
        owner: _msgSender(),
        tokenId: uint16(tokenId),
        value: uint80(krillPerAlpha)
      }); // reset stake
    }
    emit OrcaClaimed(tokenId, owed, unstake);
  }

  /**
   * emergency unstake tokens
   * @param tokenIds the IDs of the tokens to claim earnings from
   */
  function rescue(uint256[] calldata tokenIds) external {
    require(rescueEnabled, "RESCUE DISABLED");
    uint256 tokenId;
    Stake memory stake;
    Stake memory lastStake;
    uint256 alpha;
    for (uint i = 0; i < tokenIds.length; i++) {
      tokenId = tokenIds[i];
      if (isPenguin(tokenId)) {
        stake = berg[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        orca.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Penguin
        delete berg[tokenId];
        totalPenguinsStaked -= 1;
        emit PenguinClaimed(tokenId, 0, true);
      } else {
        alpha = _alphaForOrca(tokenId);
        stake = pack[alpha][packIndices[tokenId]];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        totalAlphaStaked -= alpha; // Remove Alpha from total staked
        orca.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back orca
        lastStake = pack[alpha][pack[alpha].length - 1];
        pack[alpha][packIndices[tokenId]] = lastStake; // Shuffle last Wolf to current position
        packIndices[lastStake.tokenId] = packIndices[tokenId];
        pack[alpha].pop(); // Remove duplicate
        delete packIndices[tokenId]; // Delete old mapping
        emit OrcaClaimed(tokenId, 0, true);
      }
    }
  }

  /** ACCOUNTING */

  /** 
   * add $Krill to claimable pot for the Pack
   * @param amount $Krill to add to the pot
   */
  function _payOrcaTax(uint256 amount) internal {
    if (totalAlphaStaked == 0) { // if there's no staked orcas
      unaccountedRewards += amount; // keep track of $Krill due to orcas
      return;
    }
    // makes sure to include any unaccounted $Krill
    krillPerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
    unaccountedRewards = 0;
  }

  /**
   * tracks $KRILL earnings to ensure it stops once 2.4 billion is eclipsed
   */
  modifier _updateEarnings() {
    if (totalKrillEarned < MAXIMUM_GLOBAL_KRILL) {
      totalKrillEarned += 
        (block.timestamp - lastClaimTimestamp)
        * totalPenguinsStaked
        * DAILY_KRILL_RATE / 1 days; 
      lastClaimTimestamp = block.timestamp;
    }
    _;
  }

  /** ADMIN */

  /**
   * allows owner to enable "rescue mode"
   * simplifies accounting, prioritizes tokens out in emergency
   */
  function setRescueEnabled(bool _enabled) external onlyOwner {
    rescueEnabled = _enabled;
  }

  /**
   * enables owner to pause / unpause minting
   */
  function setPaused(bool _paused) external onlyOwner {
    if (_paused) _pause();
    else _unpause();
  }

  /** READ ONLY */

  /**
   * checks if a token is a Penguin
   * @param tokenId the ID of the token to check
   * @return penguin - whether or not a token is a Penguin
   */
  function isPenguin(uint256 tokenId) public view returns (bool penguin) {
    (penguin, , , , , , , , , ) = orca.tokenTraits(tokenId);
  }

  /**
   * gets the alpha score for an Orca
   * @param tokenId the ID of the Orca to get the alpha score for
   * @return the alpha score of the Orca (5-8)
   */
  function _alphaForOrca(uint256 tokenId) internal view returns (uint8) {
    ( , , , , , , , , , uint8 alphaIndex) = orca.tokenTraits(tokenId);
    return MAX_ALPHA - alphaIndex; // alpha index is 0-3
  }

  /**
   * chooses a random Orca thief when a newly minted token is stolen
   * @param seed a random value to choose an Orca from
   * @return the owner of the randomly selected Orca thief
   */
  function randomOrcaOwner(uint256 seed) external view returns (address) {
    if (totalAlphaStaked == 0) return address(0x0);
    uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked; // choose a value from 0 to total alpha staked
    uint256 cumulative;
    seed >>= 32;
    // loop through each bucket of Wolves with the same alpha score
    for (uint i = MAX_ALPHA - 3; i <= MAX_ALPHA; i++) {
      cumulative += pack[i].length * i;
      // if the value is not inside of that bucket, keep going
      if (bucket >= cumulative) continue;
      // get the address of a random Wolf with that alpha score
      return pack[i][seed % pack[i].length].owner;
    }
    return address(0x0);
  }

  /**
   * generates a pseudorandom number
   * @param seed a value ensure different outcomes for different sources in the same block
   * @return a pseudorandom value
   */
  function random(uint256 seed) internal view returns (uint256) {
    return uint256(keccak256(abi.encodePacked(
      tx.origin,
      blockhash(block.number - 1),
      block.timestamp,
      seed
    )));
  }

  function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
      require(from == address(0x0), "Cannot send directly to Berg");
      return IERC721Receiver.onERC721Received.selector;
    }

}