// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.5.13;
pragma experimental ABIEncoderV2;

import { Test } from "celo-foundry/Test.sol";
import "@celo-contracts/common/FixidityLib.sol";
import "@celo-contracts/governance/Election.sol";
import "@celo-contracts/governance/test/MockLockedGold.sol";
import "@celo-contracts/common/Accounts.sol";
import "@celo-contracts/common/linkedlists/AddressSortedLinkedList.sol";
import "@celo-contracts/identity/test/MockRandom.sol";
import "@celo-contracts/common/Freezer.sol";
import { Constants } from "../constants.sol";
import "../utils.sol";
import "forge-std/console.sol";

contract ElectionMock is Election(true) {
  /**
   * @notice Marks a group eligible for electing validators.
   * @param group The address of the validator group.
   * @param lesser The address of the group that has received fewer votes than this group.
   * @param greater The address of the group that has received more votes than this group.
   */
  function markGroupEligible(address group, address lesser, address greater)
    external
    onlyRegisteredContract(VALIDATORS_REGISTRY_ID)
  {
    uint256 value = getTotalVotesForGroup(group);
    votes.total.eligible.insert(group, value, lesser, greater);
    emit ValidatorGroupMarkedEligible(group);
  }

  /**
   * @notice Increments the number of total and pending votes for `group`.
   * @param group The validator group to vote for.
   * @param value The amount of gold to use to vote.
   * @param lesser The group receiving fewer votes than `group`, or 0 if `group` has the
   *   fewest votes of any validator group.
   * @param greater The group receiving more votes than `group`, or 0 if `group` has the
   *   most votes of any validator group.
   * @return True upon success.
   * @dev Fails if `group` is empty or not a validator group.
   */
  function vote(address group, uint256 value, address lesser, address greater)
    external
    nonReentrant
    returns (bool)
  {
    // require(votes.total.eligible.contains(group), "Group not eligible");
    require(0 < value, "Vote value cannot be zero");
    address account = getAccounts().voteSignerToAccount(msg.sender);

    // Add group to the groups voted for by the account.
    bool alreadyVotedForGroup = false;
    address[] storage groups = votes.groupsVotedFor[account];
    for (uint256 i = 0; i < groups.length; i = i.add(1)) {
      alreadyVotedForGroup = alreadyVotedForGroup || groups[i] == group;
    }
    if (!alreadyVotedForGroup) {
      require(
        allowedToVoteOverMaxNumberOfGroups[msg.sender] || groups.length < maxNumGroupsVotedFor,
        "Voted for too many groups"
      );
      groups.push(group);
    }

    incrementPendingVotes(group, account, value);
    incrementTotalVotes(account, group, value, lesser, greater);
    getLockedGold().decrementNonvotingAccountBalance(account, value);
    emit ValidatorGroupVoteCast(account, group, value);
    return true;
  }

  /**
   * @notice Converts `account`'s pending votes for `group` to active votes.
   * @param group The validator group to vote for.
   * @return True upon success.
   * @dev Pending votes cannot be activated until an election has been held.
   */
  function activate(address group) external nonReentrant returns (bool) {
    address account = getAccounts().voteSignerToAccount(msg.sender);
    return _activate(group, account);
  }

  /**
   * @notice Converts `account`'s pending votes for `group` to active votes.
   * @param group The validator group to vote for.
   * @param account The validateor group account's pending votes to active votes
   * @return True upon success.
   * @dev Pending votes cannot be activated until an election has been held.
   */
  function activateForAccount(address group, address account) external nonReentrant returns (bool) {
    return _activate(group, account);
  }

  function _activate(address group, address account) internal returns (bool) {
    PendingVote storage pendingVote = votes.pending.forGroup[group].byAccount[account];
    uint256 value = pendingVote.value;
    require(value > 0, "Vote value cannot be zero");
    decrementPendingVotes(group, account, value);
    uint256 units = incrementActiveVotes(group, account, value);
    emit ValidatorGroupVoteActivated(account, group, value, units);
    return true;
  }

  /**
   * @notice Distributes epoch rewards to voters for `group` in the form of active votes.
   * @param group The group whose voters will receive rewards.
   * @param value The amount of rewards to distribute to voters for the group.
   * @param lesser The group receiving fewer votes than `group` after the rewards are added.
   * @param greater The group receiving more votes than `group` after the rewards are added.
   * @dev Can only be called directly by the protocol.
   */
  function distributeEpochRewards(address group, uint256 value, address lesser, address greater)
    external
  {
    _distributeEpochRewards(group, value, lesser, greater);
  }

  /**
   * @notice Distributes epoch rewards to voters for `group` in the form of active votes.
   * @param group The group whose voters will receive rewards.
   * @param value The amount of rewards to distribute to voters for the group.
   * @param lesser The group receiving fewer votes than `group` after the rewards are added.
   * @param greater The group receiving more votes than `group` after the rewards are added.
   */
  function _distributeEpochRewards(address group, uint256 value, address lesser, address greater)
    internal
  {
    if (votes.total.eligible.contains(group)) {
      uint256 newVoteTotal = votes.total.eligible.getValue(group).add(value);
      votes.total.eligible.update(group, newVoteTotal, lesser, greater);
    }

    votes.active.forGroup[group].total = votes.active.forGroup[group].total.add(value);
    votes.active.total = votes.active.total.add(value);
    emit EpochRewardsDistributedToVoters(group, value);
  }
}

contract ElectionTest is Utils, Constants {
  using FixidityLib for FixidityLib.Fraction;

  event ElectableValidatorsSet(uint256 min, uint256 max);
  event MaxNumGroupsVotedForSet(uint256 maxNumGroupsVotedFor);
  event ElectabilityThresholdSet(uint256 electabilityThreshold);
  event AllowedToVoteOverMaxNumberOfGroups(address indexed account, bool flag);
  event ValidatorGroupMarkedEligible(address indexed group);
  event ValidatorGroupMarkedIneligible(address indexed group);
  event ValidatorGroupVoteCast(address indexed account, address indexed group, uint256 value);
  event ValidatorGroupVoteActivated(
    address indexed account,
    address indexed group,
    uint256 value,
    uint256 units
  );
  event ValidatorGroupPendingVoteRevoked(
    address indexed account,
    address indexed group,
    uint256 value
  );
  event ValidatorGroupActiveVoteRevoked(
    address indexed account,
    address indexed group,
    uint256 value,
    uint256 units
  );
  event EpochRewardsDistributedToVoters(address indexed group, uint256 value);

  Accounts accounts;
  ElectionMock election;
  Freezer freezer;
  MockLockedGold lockedGold;
  MockRandom random;
  IRegistry registry;

  address registryAddress = 0x000000000000000000000000000000000000ce10;
  address nonOwner = actor("nonOwner");
  address owner = address(this);
  uint256 electableValidatorsMin = 4;
  uint256 electableValidatorsMax = 6;
  uint256 maxNumGroupsVotedFor = 3;
  uint256 electabilityThreshold = FixidityLib.newFixedFraction(1, 100).unwrap();

  address account1 = actor("account1");
  address account2 = actor("account2");
  address account3 = actor("account3");
  address account4 = actor("account4");
  address account5 = actor("account5");
  address account6 = actor("account6");
  address account7 = actor("account7");
  address account8 = actor("account8");
  address account9 = actor("account9");
  address account10 = actor("account10");

  address[] accountsArray;

  function createAccount(address account) public {
    vm.prank(account);
    accounts.createAccount();
  }

  // function setupGroupAndVote(
  //   address newGroup,
  //   address oldGroup,
  //   address[] memory members,
  //   bool vote
  // ) public {
  //   election.markGroupEligible(newGroup, oldGroup, address(0));
  //   if (vote) {
  //     election.vote(newGroup, 1, oldGroup, address(0));
  //   }
  // }

  function setUp() public {
    deployCodeTo("Registry.sol", abi.encode(false), registryAddress);

    accounts = new Accounts(true);

    accountsArray.push(account1);
    accountsArray.push(account2);
    accountsArray.push(account3);
    accountsArray.push(account4);
    accountsArray.push(account5);
    accountsArray.push(account6);
    accountsArray.push(account7);
    accountsArray.push(account8);
    accountsArray.push(account9);
    accountsArray.push(account10);

    for (uint256 i = 0; i < accountsArray.length; i++) {
      createAccount(accountsArray[i]);
    }

    createAccount(address(this));

    election = new ElectionMock();
    freezer = new Freezer(true);
    lockedGold = new MockLockedGold();
    registry = IRegistry(registryAddress);
    random = new MockRandom();

    registry.setAddressFor("Accounts", address(accounts));
    registry.setAddressFor("Freezer", address(freezer));
    registry.setAddressFor("LockedGold", address(lockedGold));
    registry.setAddressFor("Random", address(random));

    election.initialize(
      registryAddress,
      electableValidatorsMin,
      electableValidatorsMax,
      maxNumGroupsVotedFor,
      electabilityThreshold
    );
  }
}

contract ElectionTest_Initialize is ElectionTest {
  function test_shouldHaveSetOwner() public {
    assertEq(election.owner(), owner);
  }

  function test_ShouldHaveSetElectableValidators() public {
    (uint256 min, uint256 max) = election.getElectableValidators();
    assertEq(min, electableValidatorsMin);
    assertEq(max, electableValidatorsMax);
  }

  function test_ShouldHaveSetMaxNumGroupsVotedFor() public {
    assertEq(election.maxNumGroupsVotedFor(), maxNumGroupsVotedFor);
  }

  function test_ShouldHaveSetElectabilityThreshold() public {
    assertEq(election.electabilityThreshold(), electabilityThreshold);
  }

  function test_shouldRevertWhenCalledAgain() public {
    vm.expectRevert("contract already initialized");
    election.initialize(
      registryAddress,
      electableValidatorsMin,
      electableValidatorsMax,
      maxNumGroupsVotedFor,
      electabilityThreshold
    );
  }
}

contract Election_SetElectabilityThreshold is ElectionTest {
  function test_shouldSetElectabilityThreshold() public {
    uint256 newElectabilityThreshold = FixidityLib.newFixedFraction(1, 200).unwrap();
    election.setElectabilityThreshold(newElectabilityThreshold);
    assertEq(election.electabilityThreshold(), newElectabilityThreshold);
  }

  function test_ShouldRevertWhenThresholdLargerThan100Percent() public {
    vm.expectRevert("Electability threshold must be lower than 100%");
    election.setElectabilityThreshold(FixidityLib.fixed1().unwrap() + 1);
  }
}

contract Election_SetElectableValidators is ElectionTest {
  function test_shouldSetElectableValidators() public {
    uint256 newElectableValidatorsMin = 2;
    uint256 newElectableValidatorsMax = 4;
    election.setElectableValidators(newElectableValidatorsMin, newElectableValidatorsMax);
    (uint256 min, uint256 max) = election.getElectableValidators();
    assertEq(min, newElectableValidatorsMin);
    assertEq(max, newElectableValidatorsMax);
  }

  function test_ShouldEmitTheElectableValidatorsSetEvent() public {
    uint256 newElectableValidatorsMin = 2;
    uint256 newElectableValidatorsMax = 4;
    vm.expectEmit(true, false, false, false);
    emit ElectableValidatorsSet(newElectableValidatorsMin, newElectableValidatorsMax);
    election.setElectableValidators(newElectableValidatorsMin, newElectableValidatorsMax);
  }

  function test_ShouldRevertWhenMinElectableValidatorsIsZero() public {
    vm.expectRevert("Minimum electable validators cannot be zero");
    election.setElectableValidators(0, electableValidatorsMax);
  }

  function test_ShouldRevertWhenTHeminIsGreaterThanMax() public {
    vm.expectRevert("Maximum electable validators cannot be smaller than minimum");
    election.setElectableValidators(electableValidatorsMax, electableValidatorsMin);
  }

  function test_ShouldRevertWhenValuesAreUnchanged() public {
    vm.expectRevert("Electable validators not changed");
    election.setElectableValidators(electableValidatorsMin, electableValidatorsMax);
  }

  function test_ShouldRevertWhenCalledByNonOwner() public {
    vm.expectRevert("Ownable: caller is not the owner");
    vm.prank(nonOwner);
    election.setElectableValidators(1, 2);
  }
}

contract Election_SetMaxNumGroupsVotedFor is ElectionTest {
  function test_shouldSetMaxNumGroupsVotedFor() public {
    uint256 newMaxNumGroupsVotedFor = 4;
    election.setMaxNumGroupsVotedFor(newMaxNumGroupsVotedFor);
    assertEq(election.maxNumGroupsVotedFor(), newMaxNumGroupsVotedFor);
  }

  function test_ShouldEmitMaxNumGroupsVotedForSetEvent() public {
    uint256 newMaxNumGroupsVotedFor = 4;
    vm.expectEmit(true, false, false, false);
    emit MaxNumGroupsVotedForSet(newMaxNumGroupsVotedFor);
    election.setMaxNumGroupsVotedFor(newMaxNumGroupsVotedFor);
  }

  function test_ShouldRevertWhenCalledByNonOwner() public {
    vm.expectRevert("Ownable: caller is not the owner");
    vm.prank(nonOwner);
    election.setMaxNumGroupsVotedFor(1);
  }

  function test_ShouldRevert_WhenMaxNumGroupsVotedForIsUnchanged() public {
    vm.expectRevert("Max groups voted for not changed");
    election.setMaxNumGroupsVotedFor(maxNumGroupsVotedFor);
  }
}

contract Election_RevokePending is ElectionTest {
  address voter = address(this);
  address group = account1;
  uint256 value = 1000;

  uint256 index = 0;
  uint256 revokedValue = value - 1;
  uint256 remaining = value - revokedValue;

  function setUp() public {
    super.setUp();

    address[] memory members = new address[](1);
    members[0] = account9;

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));

    lockedGold.setTotalLockedGold(value);
    lockedGold.incrementNonvotingAccountBalance(voter, value);
    election.vote(group, value, address(0), address(0));
  }

  function WhenValidatorGroupHasVotesButIsIneligible() public {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    election.revokePending(group, revokedValue, address(0), address(0), index);
  }

  function test_ShouldDecrementTheAccountsPendingVotesForTheGroup_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementAccountsTotalVotesForTheGroup_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotes_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotesByAccount(voter), remaining);
  }

  function test_ShouldDecrementTotalVotesForTheGroup_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotesForGroup(group), remaining);
  }

  function test_ShouldDecrementTotalVotes_WhenValidatorGroupHasVotesButIsIneligible() public {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotes(), remaining);
  }

  function test_ShouldIncrementTheAccountsNonvotingLockedGoldBalance_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenValidatorGroupHasVotesButIsIneligible();
    assertEq(lockedGold.nonvotingAccountBalance(voter), revokedValue);
  }

  function test_ShouldEmitValidatorGroupPendingVoteRevokedEvent_WhenValidatorGroupHasVotesButIsIneligible()
    public
  {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    vm.expectEmit(true, true, true, false);
    emit ValidatorGroupPendingVoteRevoked(voter, group, revokedValue);
    election.revokePending(group, revokedValue, address(0), address(0), index);
  }

  function WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible() public {
    election.revokePending(group, revokedValue, address(0), address(0), index);
  }

  function test_ShouldDecrementTheAccountsPendingVotesForTheGroup_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementAccountsTotalVotesForTheGroup_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotes_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(election.getTotalVotesByAccount(voter), remaining);
  }

  function test_ShouldDecrementTotalVotesForTheGroup_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(election.getTotalVotesForGroup(group), remaining);
  }

  function test_ShouldDecrementTotalVotes_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(election.getTotalVotes(), remaining);
  }

  function test_ShouldIncrementTheAccountsNonvotingLockedGoldBalance_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible();
    assertEq(lockedGold.nonvotingAccountBalance(voter), revokedValue);
  }

  function test_ShouldEmitValidatorGroupPendingVoteRevokedEvent_WhenRevokedValueIsLessThanPendingVotesButGroupIsEligible()
    public
  {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    vm.expectEmit(true, true, true, false);
    emit ValidatorGroupPendingVoteRevoked(voter, group, revokedValue);
    election.revokePending(group, revokedValue, address(0), address(0), index);
  }

  function test_ShouldRemoveTheGroup_WhenCorrectIndexProvided_WhenRevokedValueIsEqualToPendingVotes()
    public
  {
    election.revokePending(group, value, address(0), address(0), index);
    assertEq(election.getGroupsVotedForByAccount(voter).length, 0);
  }

  function test_ShouldRevert_WhenWrongIndexIsProvided() public {
    vm.expectRevert("Bad index");
    election.revokePending(group, value, address(0), address(0), index + 1);
  }

  function test_ShouldRevert_WhenRevokedValuesIsGreaterThanThePendingVotes() public {
    vm.expectRevert("Vote value larger than pending votes");
    election.revokePending(group, value + 1, address(0), address(0), index);
  }
}

contract Election_RevokeActive is ElectionTest {
  address voter0 = address(this);
  address voter1 = account1;
  address group = account2;
  uint256 voteValue0 = 1000;
  uint256 reward0 = 111;
  uint256 voteValue1 = 1000;

  uint256 index = 0;
  uint256 remaining = 1;
  uint256 revokedValue = voteValue0 + reward0 - remaining;

  function assertConsistentSums() public {
    uint256 activeTotal = election.getActiveVotesForGroupByAccount(group, voter0) +
      election.getActiveVotesForGroupByAccount(group, voter1);
    uint256 pendingTotal = election.getPendingVotesForGroupByAccount(group, voter0) +
      election.getPendingVotesForGroupByAccount(group, voter1);
    uint256 totalGroup = election.getTotalVotesForGroup(group);
    assertAlmostEqual(election.getActiveVotesForGroup(group), activeTotal, 1);
    assertAlmostEqual(totalGroup, activeTotal + pendingTotal, 1);
    assertEq(election.getTotalVotes(), totalGroup);
  }

  function setUp() public {
    super.setUp();

    address[] memory members = new address[](1);
    members[0] = account9;
    // validators.setMembers(group, members);

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));
    // registry.setAddressFor("Validators", address(validators));

    lockedGold.setTotalLockedGold(voteValue0 + voteValue1);
    // validators.setNumRegisteredValidators(1);
    lockedGold.incrementNonvotingAccountBalance(voter0, voteValue0);
    lockedGold.incrementNonvotingAccountBalance(voter1, voteValue1);

    // Gives 1000 units to voter 0
    election.vote(group, voteValue0, address(0), address(0));
    assertConsistentSums();
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group);
    assertConsistentSums();

    // Makes those 1000 units represent 1111 votes.
    election.distributeEpochRewards(group, reward0, address(0), address(0));
    assertConsistentSums();

    // Gives 900 units to voter 1.
    vm.prank(voter1);
    election.vote(group, voteValue1, address(0), address(0));
    assertConsistentSums();
    blockTravel(EPOCH_SIZE + 1);
    vm.prank(voter1);
    election.activate(group);
    assertConsistentSums();
  }

  function WhenTheValidatorGroupHasVotesButIsIneligible() public {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    election.revokeActive(group, revokedValue, address(0), address(0), 0);
  }

  function test_ShouldBeConsistent_WhenTheValidatorGroupHasVotesButIsIneligible() public {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertConsistentSums();
  }

  function test_ShouldDecrementTheAccountsActiveVotesForTheGroup_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getActiveVotesForGroupByAccount(group, voter0), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotesForTheGroup_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter0), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotes_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotesByAccount(voter0), remaining);
  }

  function test_ShouldDecrementTotalVotesForTheGroup_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(
      election.getTotalVotesForGroup(group),
      voteValue0 + reward0 + voteValue1 - revokedValue
    );
  }

  function test_ShouldDecrementTotalVotes_WhenTheValidatorGroupHasVotesButIsIneligible() public {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(election.getTotalVotes(), voteValue0 + reward0 + voteValue1 - revokedValue);
  }

  function test_ShouldIncrementTheAccountsNonvotingLockedGoldBalance_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    WhenTheValidatorGroupHasVotesButIsIneligible();
    assertEq(lockedGold.nonvotingAccountBalance(voter0), revokedValue);
  }

  function test_ShouldEmitValidatorGroupActiveVoteRevokedEvent_WhenTheValidatorGroupHasVotesButIsIneligible()
    public
  {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    vm.expectEmit(true, true, true, false);
    emit ValidatorGroupActiveVoteRevoked(
      voter0,
      group,
      revokedValue,
      revokedValue * 100000000000000000000
    );
    election.revokeActive(group, revokedValue, address(0), address(0), 0);
  }

  function WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible() public {
    election.revokeActive(group, revokedValue, address(0), address(0), 0);
  }

  function test_ShouldBeConsistent_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertConsistentSums();
  }

  function test_ShouldDecrementTheAccountsActiveVotesForTheGroup_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(election.getActiveVotesForGroupByAccount(group, voter0), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotesForTheGroup_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter0), remaining);
  }

  function test_ShouldDecrementTheAccountsTotalVotes_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(election.getTotalVotesByAccount(voter0), remaining);
  }

  function test_ShouldDecrementTotalVotesForTheGroup_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(
      election.getTotalVotesForGroup(group),
      voteValue0 + reward0 + voteValue1 - revokedValue
    );
  }

  function test_ShouldDecrementTotalVotes_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(election.getTotalVotes(), voteValue0 + reward0 + voteValue1 - revokedValue);
  }

  function test_ShouldIncrementTheAccountsNonvotingLockedGoldBalance_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible();
    assertEq(lockedGold.nonvotingAccountBalance(voter0), revokedValue);
  }

  function test_ShouldEmitValidatorGroupActiveVoteRevokedEvent_WhenRevokedValueIsLessThanTheActiveVotesButGroupIsEligible()
    public
  {
    registry.setAddressFor("Validators", address(this));
    // election.markGroupIneligible(group);
    vm.expectEmit(true, true, true, false);
    emit ValidatorGroupActiveVoteRevoked(
      voter0,
      group,
      revokedValue,
      revokedValue * 100000000000000000000
    );
    election.revokeActive(group, revokedValue, address(0), address(0), 0);
  }

  function test_ShouldBeConsistent_WhenRevokeAllActive() public {
    election.revokeAllActive(group, address(0), address(0), 0);
    assertConsistentSums();
  }

  function test_ShouldDecrementAllOfTheAccountsActiveVotesForTheGroup_WhenRevokeAllActive() public {
    election.revokeAllActive(group, address(0), address(0), 0);
    assertEq(election.getActiveVotesForGroupByAccount(group, voter0), 0);
  }

  function WhenCorrectIndexIsProvided() public {
    election.revokeActive(group, voteValue0 + reward0, address(0), address(0), index);
  }

  function test_ShouldBeConsistent_WhenCorrectIndexIsProvided() public {
    WhenCorrectIndexIsProvided();
    assertConsistentSums();
  }

  function test_ShouldDecrementTheAccountsActiveVotesForTheGroup_WhenCorrectIndexIsProvided()
    public
  {
    WhenCorrectIndexIsProvided();
    assertEq(election.getActiveVotesForGroupByAccount(group, voter0), 0);
  }

  function test_ShouldDecrementTheAccountsTotalVotesForTheGroup_WhenCorrectIndexIsProvided()
    public
  {
    WhenCorrectIndexIsProvided();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter0), 0);
  }

  function test_ShouldDecrementTheAccountsTotalVotes_WhenCorrectIndexIsProvided() public {
    WhenCorrectIndexIsProvided();
    assertEq(election.getTotalVotesByAccount(voter0), 0);
  }

  function test_ShouldDecrementTotalVotesForTheGroup_WhenCorrectIndexIsProvided() public {
    WhenCorrectIndexIsProvided();
    assertEq(election.getTotalVotesForGroup(group), voteValue1);
  }

  function test_ShouldDecrementTotalVotes_WhenCorrectIndexIsProvided() public {
    WhenCorrectIndexIsProvided();
    assertEq(election.getTotalVotes(), voteValue1);
  }

  function test_ShouldIncrementTheAccountsNonvotingLockedGoldBalance_WhenCorrectIndexIsProvided()
    public
  {
    WhenCorrectIndexIsProvided();
    assertEq(lockedGold.nonvotingAccountBalance(voter0), voteValue0 + reward0);
  }

  function test_ShouldRemoveTheGroupFromTheListOfGroupsTheAccountHasVotedFor_WhenCorrectIndexIsProvided()
    public
  {
    WhenCorrectIndexIsProvided();
    assertEq(election.getGroupsVotedForByAccount(voter0).length, 0);
  }

  function test_ShouldRevert_WhenWrongIndexIsProvided() public {
    vm.expectRevert("Bad index");
    election.revokeActive(group, voteValue0 + reward0, address(0), address(0), index + 1);
  }

  function test_ShouldRevert_WhenRevokedValueIsGreaterThanTheActiveVotes() public {
    vm.expectRevert("Vote value larger than active votes");
    election.revokeActive(group, voteValue0 + reward0 + 1, address(0), address(0), index);
  }

}

// contract Election_ElectionValidatorSigners is ElectionTest {
//   address group1 = address(this);
//   address group2 = account1;
//   address group3 = account2;

//   address validator1 = account3;
//   address validator2 = account4;
//   address validator3 = account5;
//   address validator4 = account6;
//   address validator5 = account7;
//   address validator6 = account8;
//   address validator7 = account9;

//   address[] group1Members = new address[](4);
//   address[] group2Members = new address[](2);
//   address[] group3Members = new address[](1);

//   bytes32 hash = 0xa5b9d60f32436310afebcfda832817a68921beb782fabf7915cc0460b443116a;

//   // If voterN votes for groupN:
//   //   group1 gets 20 votes per member
//   //   group2 gets 25 votes per member
//   //   group3 gets 30 votes per member
//   // We cannot make any guarantee with respect to their ordering.
//   address voter1 = address(this);
//   address voter2 = account1;
//   address voter3 = account2;

//   uint256 voter1Weight = 80;
//   uint256 voter2Weight = 50;
//   uint256 voter3Weight = 30;

//   uint256 totalLockedGold = voter1Weight + voter2Weight + voter3Weight;

//   struct MemberWithVotes {
//     address member;
//     uint256 votes;
//   }

//   mapping(address => uint256) votesConsideredForElection;

//   MemberWithVotes[] membersWithVotes;

//   function setUp() public {
//     super.setUp();

//     group1Members[0] = validator1;
//     group1Members[1] = validator2;
//     group1Members[2] = validator3;
//     group1Members[3] = validator4;

//     group2Members[0] = validator5;
//     group2Members[1] = validator6;

//     group3Members[0] = validator7;
//   }

//   function setRandomness() public {
//     random.addTestRandomness(block.number + 1, hash);
//   }

//   // Helper function to sort an array of uint256
//   function sort(uint256[] memory data) internal pure returns (uint256[] memory) {
//     uint256 length = data.length;
//     for (uint256 i = 0; i < length; i++) {
//       for (uint256 j = i + 1; j < length; j++) {
//         if (data[i] > data[j]) {
//           uint256 temp = data[i];
//           data[i] = data[j];
//           data[j] = temp;
//         }
//       }
//     }
//     return data;
//   }

//   function sortMembersWithVotesDesc(MemberWithVotes[] memory data)
//     internal
//     pure
//     returns (MemberWithVotes[] memory)
//   {
//     uint256 length = data.length;
//     for (uint256 i = 0; i < length; i++) {
//       for (uint256 j = i + 1; j < length; j++) {
//         if (data[i].votes < data[j].votes) {
//           MemberWithVotes memory temp = data[i];
//           data[i] = data[j];
//           data[j] = temp;
//         }
//       }
//     }
//     return data;
//   }

//   function WhenThereIsALargeNumberOfGroups() public {
//     lockedGold.setTotalLockedGold(1e25);
//     // validators.setNumRegisteredValidators(400);
//     lockedGold.incrementNonvotingAccountBalance(voter1, 1e25);
//     election.setElectabilityThreshold(0);
//     election.setElectableValidators(10, 100);

//     election.setMaxNumGroupsVotedFor(200);

//     address prev = address(0);
//     uint256[] memory randomVotes = new uint256[](100);
//     for (uint256 i = 0; i < 100; i++) {
//       randomVotes[i] = uint256(keccak256(abi.encodePacked(i))) % 1e14;
//     }
//     randomVotes = sort(randomVotes);
//     for (uint256 i = 0; i < 100; i++) {
//       address group = actor(string(abi.encodePacked("group", i)));
//       address[] memory members = new address[](4);
//       for (uint256 j = 0; j < 4; j++) {
//         members[j] = actor(string(abi.encodePacked("group", i, "member", j)));
//         // If there are already n elected members in a group, the votes for the next member
//         // are total votes of group divided by n+1
//         votesConsideredForElection[members[j]] = randomVotes[i] / (j + 1);
//         membersWithVotes.push(MemberWithVotes(members[j], votesConsideredForElection[members[j]]));
//       }
//       // validators.setMembers(group, members);
//       registry.setAddressFor("Validators", address(this));
//       // election.markGroupEligible(group, address(0), prev);
//       // registry.setAddressFor("Validators", address(validators));
//       vm.prank(voter1);
//       election.vote(group, randomVotes[i], prev, address(0));
//       prev = group;
//     }
//   }

//   // function test_ShouldElectCorrectValidators_WhenThereIsALargeNumberOfGroups() public {
//   //   WhenThereIsALargeNumberOfGroups();
//   //   // address[] memory elected = election.electValidatorSigners();
//   //   MemberWithVotes[] memory sortedMembersWithVotes = sortMembersWithVotesDesc(membersWithVotes);
//   //   MemberWithVotes[] memory electedUnsorted = new MemberWithVotes[](100);

//   //   for (uint256 i = 0; i < 100; i++) {
//   //     // electedUnsorted[i] = MemberWithVotes(elected[i], votesConsideredForElection[elected[i]]);
//   //   }
//   //   MemberWithVotes[] memory electedSorted = sortMembersWithVotesDesc(electedUnsorted);

//   //   for (uint256 i = 0; i < 100; i++) {
//   //     assertEq(electedSorted[i].member, sortedMembersWithVotes[i].member);
//   //     assertEq(electedSorted[i].votes, sortedMembersWithVotes[i].votes);
//   //   }
//   // }

//   function WhenThereAreSomeGroups() public {
//     // validators.setMembers(group1, group1Members);
//     // validators.setMembers(group2, group2Members);
//     // validators.setMembers(group3, group3Members);

//     registry.setAddressFor("Validators", address(this));
//     // election.markGroupEligible(group1, address(0), address(0));
//     // election.markGroupEligible(group2, address(0), group1);
//     // election.markGroupEligible(group3, address(0), group2);
//     // registry.setAddressFor("Validators", address(validators));

//     lockedGold.incrementNonvotingAccountBalance(address(voter1), voter1Weight);
//     lockedGold.incrementNonvotingAccountBalance(address(voter2), voter2Weight);
//     lockedGold.incrementNonvotingAccountBalance(address(voter3), voter3Weight);

//     lockedGold.setTotalLockedGold(totalLockedGold);
//     // validators.setNumRegisteredValidators(7);
//   }

//   function test_ShouldReturnThatGroupsMemberLIst_WhenASingleGroupHasMoreOrEqualToMinElectableValidatorsAsMembersAndReceivedVotes()
//     public
//   {
//     WhenThereAreSomeGroups();
//     vm.prank(voter1);
//     election.vote(group1, voter1Weight, group2, address(0));
//     setRandomness();
//     // arraysEqual(election.electValidatorSigners(), group1Members);
//   }

//   function test_ShouldReturnMaxElectableValidatorsElectedValidators_WhenGroupWithMoreThenMaxElectableValidatorsMembersReceivesVotes()
//     public
//   {
//     WhenThereAreSomeGroups();
//     vm.prank(voter1);
//     election.vote(group1, voter1Weight, group2, address(0));
//     vm.prank(voter2);
//     election.vote(group2, voter2Weight, address(0), group1);
//     vm.prank(voter3);
//     election.vote(group3, voter3Weight, address(0), group2);

//     setRandomness();
//     address[] memory expected = new address[](6);
//     expected[0] = validator1;
//     expected[1] = validator2;
//     expected[2] = validator3;
//     expected[3] = validator5;
//     expected[4] = validator6;
//     expected[5] = validator7;
//     // arraysEqual(election.electValidatorSigners(), expected);
//   }

//   function test_ShouldElectOnlyNMembersFromThatGroup_WhenAGroupReceivesEnoughVotesForMoreThanNSeatsButOnlyHasNMembers()
//     public
//   {
//     WhenThereAreSomeGroups();
//     uint256 increment = 80;
//     uint256 votes = 80;
//     lockedGold.incrementNonvotingAccountBalance(address(voter3), increment);
//     lockedGold.setTotalLockedGold(totalLockedGold + increment);
//     vm.prank(voter3);
//     election.vote(group3, votes, group2, address(0));
//     vm.prank(voter1);
//     election.vote(group1, voter1Weight, address(0), group3);
//     vm.prank(voter2);
//     election.vote(group2, voter2Weight, address(0), group1);
//     setRandomness();

//     address[] memory expected = new address[](6);
//     expected[0] = validator1;
//     expected[1] = validator2;
//     expected[2] = validator3;
//     expected[3] = validator5;
//     expected[4] = validator6;
//     expected[5] = validator7;
//     // arraysEqual(election.electValidatorSigners(), expected);
//   }

//   function test_ShouldNotElectAnyMembersFromThatGroup_WhenAGroupDoesNotReceiveElectabilityThresholdVotes()
//     public
//   {
//     WhenThereAreSomeGroups();
//     uint256 thresholdExcludingGroup3 = (voter3Weight + 1) / totalLockedGold;
//     election.setElectabilityThreshold(thresholdExcludingGroup3);
//     vm.prank(voter1);
//     election.vote(group1, voter1Weight, group2, address(0));
//     vm.prank(voter2);
//     election.vote(group2, voter2Weight, address(0), group1);
//     vm.prank(voter3);
//     election.vote(group3, voter3Weight, address(0), group2);

//     address[] memory expected = new address[](6);
//     expected[0] = validator1;
//     expected[1] = validator2;
//     expected[2] = validator3;
//     expected[3] = validator4;
//     expected[4] = validator5;
//     expected[5] = validator6;
//     // arraysEqual(election.electValidatorSigners(), expected);
//   }

//   function test_ShouldRevert_WhenThereAnoNotEnoughElectableValidators() public {
//     WhenThereAreSomeGroups();
//     vm.prank(voter2);
//     election.vote(group2, voter2Weight, group1, address(0));
//     vm.prank(voter3);
//     election.vote(group3, voter3Weight, address(0), group2);
//     setRandomness();
//     vm.expectRevert("Not enough elected validators");
//     // election.electValidatorSigners();
//   }
// }

contract Election_GetGroupEpochRewards is ElectionTest {
  address voter = address(this);
  address group1 = account2;
  address group2 = account3;
  uint256 voteValue1 = 2000000000;
  uint256 voteValue2 = 1000000000;
  uint256 totalRewardValue = 3000000000;

  function setUp() public {
    super.setUp();

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group1, address(0), address(0));
    election.markGroupEligible(group2, address(0), group1);
    // registry.setAddressFor("Validators", address(validators));
    lockedGold.setTotalLockedGold(voteValue1 + voteValue2);

    address[] memory membersGroup1 = new address[](1);
    membersGroup1[0] = account8;

    // validators.setMembers(group1, membersGroup1);

    address[] memory membersGroup2 = new address[](1);
    membersGroup2[0] = account9;
    // validators.setMembers(group2, membersGroup2);
    // validators.setNumRegisteredValidators(2);
    lockedGold.incrementNonvotingAccountBalance(voter, voteValue1 + voteValue2);
    election.vote(group1, voteValue1, group2, address(0));
    election.vote(group2, voteValue2, address(0), group1);
  }

  function WhenOneGroupHasActiveVotes() public {
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group1);
  }

  // function test_ShouldReturnTheTotalRewardValue_WhenGroupUptimeIs100Percent_WhenOneGroupHasActiveVotes()
  //   public
  // {
  //   WhenOneGroupHasActiveVotes();

  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1;
  //   assertEq(election.getGroupEpochRewards(group1, totalRewardValue, uptimes), totalRewardValue);
  // }

  // function test_ShouldReturnPartOfTheTotalRewardValue_WhenWhenGroupUptimeIsLessThan100Percent_WhenOneGroupHasActiveVotes()
  //   public
  // {
  //   WhenOneGroupHasActiveVotes();

  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1 / 2;
  //   assertEq(
  //     election.getGroupEpochRewards(group1, totalRewardValue, uptimes),
  //     totalRewardValue / 2
  //   );
  // }

  // function test_ShouldReturnZero_WhenTheGroupDoesNotMeetTheLockedGoldRequirements_WhenOneGroupHasActiveVotes()
  //   public
  // {
  //   WhenOneGroupHasActiveVotes();

  //   // validators.setDoesNotMeetAccountLockedGoldRequirements(group1);
  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1;
  //   assertEq(election.getGroupEpochRewards(group1, totalRewardValue, uptimes), 0);
  // }

  function WhenTwoGroupsHaveActiveVotes() public {
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group1);
    election.activate(group2);
  }

  // function test_ShouldReturn0_WhenOneGroupDoesNotMeetLockedGoldRequirements_WhenTwoGroupsHaveActiveVotes()
  //   public
  // {
  //   WhenTwoGroupsHaveActiveVotes();

  //   // validators.setDoesNotMeetAccountLockedGoldRequirements(group2);
  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1;
  //   assertEq(election.getGroupEpochRewards(group2, totalRewardValue, uptimes), 0);
  // }

  uint256 expectedGroup1EpochRewards = FixidityLib
    .newFixedFraction(voteValue1, voteValue1 + voteValue2)
    .multiply(FixidityLib.newFixed(totalRewardValue))
    .fromFixed();

  // function test_ShouldReturnProportionalRewardValueForOtherGroup_WhenOneGroupDoesNotMeetLockedGoldRequirements_WhenTwoGroupsHaveActiveVotes()
  //   public
  // {
  //   WhenTwoGroupsHaveActiveVotes();

  //   // validators.setDoesNotMeetAccountLockedGoldRequirements(group2);
  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1;

  //   assertEq(
  //     election.getGroupEpochRewards(group1, totalRewardValue, uptimes),
  //     expectedGroup1EpochRewards
  //   );
  // }

  // function test_ShouldReturn0_WhenTheGroupMeetsLockedGoldRequirements_WhenThenGroupDoesNotHaveActiveVotes()
  //   public
  // {
  //   uint256[] memory uptimes = new uint256[](1);
  //   uptimes[0] = FIXED1;
  //   assertEq(election.getGroupEpochRewards(group1, totalRewardValue, uptimes), 0);
  // }

}

// contract Election_DistributeEpochRewards is ElectionTest {
//   address voter = address(this);
//   address voter2 = account4;
//   address group = account2;
//   address group2 = account3;
//   uint256 voteValue = 1000000;
//   uint256 voteValue2 = 1000000;
//   uint256 rewardValue = 1000000;
//   uint256 rewardValue2 = 10000000;

//   function setUp() public {
//     super.setUp();

//     registry.setAddressFor("Validators", address(this));
//     election.markGroupEligible(group, address(0), address(0));
//     // registry.setAddressFor("Validators", address(validators));
//     lockedGold.setTotalLockedGold(voteValue);

//     address[] memory membersGroup = new address[](1);
//     membersGroup[0] = account8;

//     // validators.setMembers(group, membersGroup);

//     // validators.setNumRegisteredValidators(1);
//     lockedGold.incrementNonvotingAccountBalance(voter, voteValue);
//     election.vote(group, voteValue, address(0), address(0));

//     blockTravel(EPOCH_SIZE + 1);
//     election.activate(group);
//   }

//   function test_ShouldIncrementTheAccountActiveVotesForGroup_WhenThereIsSingleGroupWithActiveVotes()
//     public
//   {
//     election.distributeEpochRewards(group, rewardValue, address(0), address(0));
//     assertEq(election.getActiveVotesForGroupByAccount(group, voter), voteValue + rewardValue);
//   }

//   function test_ShouldIncrementAccountTotalVotesForGroup_WhenThereIsSingleGroupWithActiveVotes()
//     public
//   {
//     election.distributeEpochRewards(group, rewardValue, address(0), address(0));
//     assertEq(election.getTotalVotesForGroupByAccount(group, voter), voteValue + rewardValue);
//   }

//   function test_ShouldIncrementAccountTotalVotes_WhenThereIsSingleGroupWithActiveVotes() public {
//     election.distributeEpochRewards(group, rewardValue, address(0), address(0));
//     assertEq(election.getTotalVotesByAccount(voter), voteValue + rewardValue);
//   }

//   function test_ShouldIncrementTotalVotesForGroup_WhenThereIsSingleGroupWithActiveVotes() public {
//     election.distributeEpochRewards(group, rewardValue, address(0), address(0));
//     assertEq(election.getTotalVotesForGroup(group), voteValue + rewardValue);
//   }

//   function test_ShouldIncrementTotalVotes_WhenThereIsSingleGroupWithActiveVotes() public {
//     election.distributeEpochRewards(group, rewardValue, address(0), address(0));
//     assertEq(election.getTotalVotes(), voteValue + rewardValue);
//   }

//   uint256 expectedGroupTotalActiveVotes = voteValue + voteValue2 / 2 + rewardValue;
//   uint256 expectedVoterActiveVotesForGroup = FixidityLib
//     .newFixedFraction(expectedGroupTotalActiveVotes * 2, 3)
//     .fromFixed();
//   uint256 expectedVoter2ActiveVotesForGroup = FixidityLib
//     .newFixedFraction(expectedGroupTotalActiveVotes, 3)
//     .fromFixed();
//   uint256 expectedVoter2ActiveVotesForGroup2 = voteValue / 2 + rewardValue2;

//   function WhenThereAreTwoGroupsWithActiveVotes() public {
//     registry.setAddressFor("Validators", address(this));
//     election.markGroupEligible(group2, address(0), group);
//     // registry.setAddressFor("Validators", address(validators));
//     lockedGold.setTotalLockedGold(voteValue + voteValue2);

//     // validators.setNumRegisteredValidators(2);
//     lockedGold.incrementNonvotingAccountBalance(voter2, voteValue2);

//     vm.startPrank(voter2);
//     // Split voter2's vote between the two groups.
//     election.vote(group, voteValue2 / 2, group2, address(0));
//     election.vote(group2, voteValue2 / 2, address(0), group);
//     blockTravel(EPOCH_SIZE + 1);
//     election.activate(group);
//     election.activate(group2);
//     vm.stopPrank();

//     election.distributeEpochRewards(group, rewardValue, group2, address(0));
//     election.distributeEpochRewards(group2, rewardValue2, group, address(0));
//   }

//   function test_ShouldIncrementTheAccountsActiveVotesForBothGroups_WhenThereAreTwoGroupsWithActiveVotes()
//     public
//   {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(
//       election.getActiveVotesForGroupByAccount(group, voter),
//       expectedVoterActiveVotesForGroup
//     );
//     assertEq(
//       election.getActiveVotesForGroupByAccount(group, voter2),
//       expectedVoter2ActiveVotesForGroup
//     );
//     assertEq(
//       election.getActiveVotesForGroupByAccount(group2, voter2),
//       expectedVoter2ActiveVotesForGroup2
//     );
//   }

//   function test_ShouldIncrementTheAccountsTotalVOtesForBothGroups_WhenThereAreTwoGroupsWithActiveVotes()
//     public
//   {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(
//       election.getTotalVotesForGroupByAccount(group, voter),
//       expectedVoterActiveVotesForGroup
//     );
//     assertEq(
//       election.getTotalVotesForGroupByAccount(group, voter2),
//       expectedVoter2ActiveVotesForGroup
//     );
//     assertEq(
//       election.getTotalVotesForGroupByAccount(group2, voter2),
//       expectedVoter2ActiveVotesForGroup2
//     );
//   }

//   function test_ShouldIncrementTheAccountsTotalVotes_WhenThereAreTwoGroupsWithActiveVotes() public {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(election.getTotalVotesByAccount(voter), expectedVoterActiveVotesForGroup);
//     assertEq(
//       election.getTotalVotesByAccount(voter2),
//       expectedVoter2ActiveVotesForGroup + expectedVoter2ActiveVotesForGroup2
//     );
//   }

//   function test_ShouldIncrementTotalVotesForBothGroups_WhenThereAreTwoGroupsWithActiveVotes()
//     public
//   {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(election.getTotalVotesForGroup(group), expectedGroupTotalActiveVotes);
//     assertEq(election.getTotalVotesForGroup(group2), expectedVoter2ActiveVotesForGroup2);
//   }

//   function test_ShouldIncrementTotalVotes_WhenThereAreTwoGroupsWithActiveVotes() public {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(
//       election.getTotalVotes(),
//       expectedGroupTotalActiveVotes + expectedVoter2ActiveVotesForGroup2
//     );
//   }

//   function test_ShouldUpdateTheORderingOFEligibleGroups_WhenThereAreTwoGroupsWithActiveVotes()
//     public
//   {
//     WhenThereAreTwoGroupsWithActiveVotes();
//     assertEq(election.getEligibleValidatorGroups().length, 2);
//     assertEq(election.getEligibleValidatorGroups()[0], group2);
//     assertEq(election.getEligibleValidatorGroups()[1], group);
//   }
// }

contract Election_ForceDecrementVotes is ElectionTest {
  address voter = address(this);
  address group = account2;
  address group2 = account7;
  uint256 value = 1000;
  uint256 value2 = 1500;
  uint256 index = 0;
  uint256 slashedValue = value;
  uint256 remaining = value - slashedValue;

  function setUp() public {
    super.setUp();

  }

  function WhenAccountHasVotedForOneGroup() public {
    address[] memory membersGroup = new address[](1);
    membersGroup[0] = account8;

    // validators.setMembers(group, membersGroup);

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));
    // registry.setAddressFor("Validators", address(validators));
    lockedGold.setTotalLockedGold(value);
    // validators.setNumRegisteredValidators(1);
    lockedGold.incrementNonvotingAccountBalance(voter, value);
    election.vote(group, value, address(0), address(0));

    registry.setAddressFor("LockedGold", account2);
  }

  function WhenAccountHasOnlyPendingVotes() public {
    WhenAccountHasVotedForOneGroup();
    address[] memory lessers = new address[](1);
    lessers[0] = address(0);
    address[] memory greaters = new address[](1);
    greaters[0] = address(0);
    uint256[] memory indices = new uint256[](1);
    indices[0] = index;

    vm.prank(account2);
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function test_ShouldDecrementPendingVotesToZero_WhenAccountHasOnlyPendingVotes() public {
    WhenAccountHasOnlyPendingVotes();
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementTotalVotesToZero_WhenAccountHasOnlyPendingVotes() public {
    WhenAccountHasOnlyPendingVotes();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
    assertEq(election.getTotalVotesByAccount(voter), remaining);
    assertEq(election.getTotalVotesForGroup(group), remaining);
    assertEq(election.getTotalVotes(), remaining);
  }

  function test_ShouldRemoveTheGroupFromTheVotersVotedSet_WhenAccountHasOnlyPendingVotes() public {
    WhenAccountHasOnlyPendingVotes();
    assertEq(election.getGroupsVotedForByAccount(voter).length, 0);
  }

  function WhenAccountHasOnlyActiveVotes() public {
    WhenAccountHasVotedForOneGroup();
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group);
    vm.prank(account2);

    address[] memory lessers = new address[](1);
    lessers[0] = address(0);
    address[] memory greaters = new address[](1);
    greaters[0] = address(0);
    uint256[] memory indices = new uint256[](1);
    indices[0] = index;

    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function test_ShouldDecrementActiveVotesToZero_WhenAccountHasOnlyActiveVotes() public {
    WhenAccountHasOnlyActiveVotes();
    assertEq(election.getActiveVotesForGroupByAccount(group, voter), remaining);
  }

  function test_ShouldDecrementTotalVotesToZero_WhenAccountHasOnlyActiveVotes() public {
    WhenAccountHasOnlyActiveVotes();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
    assertEq(election.getTotalVotesByAccount(voter), remaining);
    assertEq(election.getTotalVotesForGroup(group), remaining);
    assertEq(election.getTotalVotes(), remaining);
  }

  function test_ShouldRemoveTheGroupFromTheVotersVotedSet_WhenAccountHasOnlyActiveVotes() public {
    WhenAccountHasOnlyActiveVotes();
    assertEq(election.getGroupsVotedForByAccount(voter).length, 0);
  }

  function WhenAccountHasVotedForMoreThanOneGroupEqually() public {
    address[] memory membersGroup = new address[](1);
    membersGroup[0] = account8;
    // validators.setMembers(group, membersGroup);

    address[] memory membersGroup2 = new address[](1);
    membersGroup2[0] = account9;
    // validators.setMembers(group2, membersGroup2);

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));
    election.markGroupEligible(group2, group, address(0));
    // registry.setAddressFor("Validators", address(validators));
    lockedGold.setTotalLockedGold(value);
    // validators.setNumRegisteredValidators(2);
    lockedGold.incrementNonvotingAccountBalance(voter, value);
    election.vote(group, value / 2, group2, address(0));
    election.vote(group2, value / 2, address(0), group);
    registry.setAddressFor("LockedGold", account2);
  }

  function forceDecrementVotes2Groups(
    address lesser0,
    address lesser1,
    address greater0,
    address greater1
  ) public {
    address[] memory lessers = new address[](2);
    lessers[0] = lesser0;
    lessers[1] = lesser1;
    address[] memory greaters = new address[](2);
    greaters[0] = greater0;
    greaters[1] = greater1;
    uint256[] memory indices = new uint256[](2);
    indices[0] = 0;
    indices[1] = 1;

    vm.prank(account2);
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function WhenAccountsOnlyHavePendingVotes() public {
    WhenAccountHasVotedForMoreThanOneGroupEqually();
    forceDecrementVotes2Groups(group2, address(0), address(0), group);
  }

  function test_ShouldDecrementBothGroupPendingVotesToZero_WhenAccountsOnlyHavePendingVotes_WhenAccountHasVotedForMoreThanOneGroupEqually()
    public
  {
    WhenAccountsOnlyHavePendingVotes();
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), remaining);
    assertEq(election.getPendingVotesForGroupByAccount(group2, voter), remaining);
  }

  function test_ShouldDecrementBothGroupTotalVotesToZero_WhenAccountsOnlyHavePendingVotes_WhenAccountHasVotedForMoreThanOneGroupEqually()
    public
  {
    WhenAccountsOnlyHavePendingVotes();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
    assertEq(election.getTotalVotesForGroupByAccount(group2, voter), remaining);
    assertEq(election.getTotalVotesByAccount(voter), remaining);
    assertEq(election.getTotalVotesForGroup(group), remaining);
    assertEq(election.getTotalVotesForGroup(group2), remaining);
    assertEq(election.getTotalVotes(), remaining);
  }

  function test_ShouldRemoveBothGroupsFromTheVotersVotedSet_WhenAccountsOnlyHavePendingVotes_WhenAccountHasVotedForMoreThanOneGroupEqually()
    public
  {
    WhenAccountsOnlyHavePendingVotes();
    assertEq(election.getGroupsVotedForByAccount(voter).length, 0);
  }

  function WhenAccountHasVotedForMoreThanOneGroupInequally() public {
    address[] memory membersGroup = new address[](1);
    membersGroup[0] = account8;
    // validators.setMembers(group, membersGroup);

    address[] memory membersGroup2 = new address[](1);
    membersGroup2[0] = account9;
    // validators.setMembers(group2, membersGroup2);

    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));
    election.markGroupEligible(group2, group, address(0));
    // registry.setAddressFor("Validators", address(validators));
    lockedGold.setTotalLockedGold(value + value2);
    // validators.setNumRegisteredValidators(2);
    lockedGold.incrementNonvotingAccountBalance(voter, value + value2);
    election.vote(group2, value2 / 2, group, address(0));
    election.vote(group, value / 2, address(0), group2);
  }

  function WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenAccountHasVotedForMoreThanOneGroupInequally();
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group);
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group2);

    election.vote(group2, value2 / 2, group, address(0));
    election.vote(group, value / 2, address(0), group2);

    registry.setAddressFor("LockedGold", account2);

    slashedValue = value / 2 + 1;
    remaining = value - slashedValue;
  }

  function WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequally();
    forceDecrementVotes2Groups(address(0), address(0), group, group2);
  }

  function test_ShouldNotAffectGroup2_WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement();

    assertEq(election.getTotalVotesForGroupByAccount(group2, voter), value2);
    assertEq(election.getTotalVotesForGroup(group2), value2);
  }

  function test_ShouldReduceGroup1Votes_WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement();

    assertEq(election.getTotalVotesForGroupByAccount(group, voter), remaining);
    assertEq(election.getTotalVotesForGroup(group), remaining);
  }

  function test_ShouldReduceVoterTotalVotes_WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement();

    assertEq(election.getTotalVotesByAccount(voter), remaining + value2);
  }

  function test_ShouldReduceGroup1PendingVotesTo0_WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement();
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), 0);
  }

  function test_ShouldReduceGroup1ActiveVotesBy1_WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequallyWithDecrement();
    assertEq(election.getActiveVotesForGroupByAccount(group, voter), remaining);
  }

  uint256 totalRemaining;
  uint256 group1Remaining;
  uint256 group2TotalRemaining;
  uint256 group2PendingRemaining;
  uint256 group2ActiveRemaining;

  function WhenWeSlashAllOfGroup1VotesAndSomeOfGroup2__WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenBothGroupsHaveBothPendingAndActiveVotes_WhenAccountHasVotedForMoreThanOneGroupInequally();

    slashedValue = value + 1;

    totalRemaining = value + value2 - slashedValue;
    group1Remaining = 0;
    group2TotalRemaining = value2 - 1;
    group2PendingRemaining = value2 / 2 - 1;
    group2ActiveRemaining = value2 / 2;

    forceDecrementVotes2Groups(group, address(0), address(0), group2);
  }

  function test_ShouldDecrementGroup1Votes_WhenWeSlashAllOfGroup1VotesAndSomeOfGroup2__WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenWeSlashAllOfGroup1VotesAndSomeOfGroup2__WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), group1Remaining);
    assertEq(election.getTotalVotesForGroup(group), group1Remaining);
    assertEq(election.getPendingVotesForGroupByAccount(group, voter), group1Remaining);
    assertEq(election.getActiveVotesForGroupByAccount(group, voter), group1Remaining);
  }

  function test_ShouldDecrementGroup2Votes_WhenWeSlashAllOfGroup1VotesAndSomeOfGroup2__WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally()
    public
  {
    WhenWeSlashAllOfGroup1VotesAndSomeOfGroup2__WhenWeSlash1MoreVoteThanGroup1PendingVoteTotal_WhenAccountHasVotedForMoreThanOneGroupInequally();
    assertEq(election.getTotalVotesForGroupByAccount(group2, voter), group2TotalRemaining);
    assertEq(election.getTotalVotesByAccount(voter), totalRemaining);
    assertEq(election.getPendingVotesForGroupByAccount(group2, voter), group2PendingRemaining);
    assertEq(election.getActiveVotesForGroupByAccount(group2, voter), group2ActiveRemaining);
  }

  uint256 group1RemainingActiveVotes;
  address[] initialOrdering;

  function WhenSlashAffectsElectionOrder() public {
    WhenAccountHasVotedForMoreThanOneGroupInequally();

    slashedValue = value / 4;
    group1RemainingActiveVotes = value - slashedValue;

    election.vote(group, value / 2, group2, address(0));
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group);
    blockTravel(EPOCH_SIZE + 1);
    election.activate(group2);

    (initialOrdering, ) = election.getTotalVotesForEligibleValidatorGroups();
    registry.setAddressFor("LockedGold", account2);

    forceDecrementVotes2Groups(group, address(0), address(0), group2);
  }

  function test_ShouldDecrementGroup1TotalVotesByOneQuarter_WhenSlashAffectsElectionOrder() public {
    WhenSlashAffectsElectionOrder();
    assertEq(election.getTotalVotesForGroupByAccount(group, voter), group1RemainingActiveVotes);
    assertEq(election.getTotalVotesForGroup(group), group1RemainingActiveVotes);
  }

  function test_ShouldChangeTheOrderingOfTheElection_WhenSlashAffectsElectionOrder() public {
    WhenSlashAffectsElectionOrder();
    (address[] memory newOrdering, ) = election.getTotalVotesForEligibleValidatorGroups();
    assertEq(newOrdering[0], initialOrdering[1]);
    assertEq(newOrdering[1], initialOrdering[0]);
  }

  function test_ShouldRevert_WhenCalledToSlashMoreValueThanGroupsHave_WhenCalledWithMalformedInputs()
    public
  {
    WhenAccountHasVotedForMoreThanOneGroupInequally();
    slashedValue = value + value2 + 1;
    address[] memory lessers = new address[](2);
    lessers[0] = group;
    lessers[1] = address(0);
    address[] memory greaters = new address[](2);
    greaters[0] = address(0);
    greaters[1] = group2;
    uint256[] memory indices = new uint256[](2);
    indices[0] = 0;
    indices[1] = 1;

    registry.setAddressFor("LockedGold", account2);
    vm.prank(account2);
    vm.expectRevert("Failure to decrement all votes.");
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function test_ShouldRevert_WhenCalledToSlashWithIncorrectLessersGreaters_WhenCalledWithMalformedInputs()
    public
  {
    WhenAccountHasVotedForMoreThanOneGroupInequally();
    slashedValue = value;
    address[] memory lessers = new address[](2);
    lessers[0] = address(0);
    lessers[1] = address(0);
    address[] memory greaters = new address[](2);
    greaters[0] = address(0);
    greaters[1] = group2;
    uint256[] memory indices = new uint256[](2);
    indices[0] = 0;
    indices[1] = 1;

    registry.setAddressFor("LockedGold", account2);
    vm.prank(account2);
    vm.expectRevert("greater and lesser key zero");
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function test_ShouldRevert_WhenCalledToSlashWithIncorrectIndices_WhenCalledWithMalformedInputs()
    public
  {
    WhenAccountHasVotedForMoreThanOneGroupInequally();
    slashedValue = value;
    address[] memory lessers = new address[](2);
    lessers[0] = address(0);
    lessers[1] = address(0);
    address[] memory greaters = new address[](2);
    greaters[0] = address(0);
    greaters[1] = group2;
    uint256[] memory indices = new uint256[](2);
    indices[0] = 0;
    indices[1] = 0;

    registry.setAddressFor("LockedGold", account2);
    vm.prank(account2);
    vm.expectRevert("Bad index");
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }

  function test_ShouldRevert_WhenCalledByAnyoneElseThanLockedGoldContract_WhenCalledWithMalformedInputs()
    public
  {
    WhenAccountHasVotedForMoreThanOneGroupInequally();
    slashedValue = value;
    address[] memory lessers = new address[](2);
    lessers[0] = address(0);
    lessers[1] = address(0);
    address[] memory greaters = new address[](2);
    greaters[0] = address(0);
    greaters[1] = group2;
    uint256[] memory indices = new uint256[](2);
    indices[0] = 0;
    indices[1] = 0;

    vm.expectRevert("only registered contract");
    election.forceDecrementVotes(voter, slashedValue, lessers, greaters, indices);
  }
}

contract Election_ConsistencyChecks is ElectionTest {
  address voter = address(this);
  address group = account2;
  uint256 rewardValue2 = 10000000;

  AccountStruct[] _accounts;

  struct AccountStruct {
    address account;
    uint256 active;
    uint256 pending;
    uint256 nonVoting;
  }

  enum VoteActionType { Vote, Activate, RevokePending, RevokeActive }

  function setUp() public {
    super.setUp();

    // 50M gives us 500M total locked gold
    uint256 voterStartBalance = 50000000 ether;
    address[] memory members = new address[](1);
    members[0] = account9;
    // validators.setMembers(group, members);
    registry.setAddressFor("Validators", address(this));
    election.markGroupEligible(group, address(0), address(0));
    // registry.setAddressFor("Validators", address(validators));
    lockedGold.setTotalLockedGold(voterStartBalance * accountsArray.length);
    // validators.setNumRegisteredValidators(1);
    for (uint256 i = 0; i < accountsArray.length; i++) {
      lockedGold.incrementNonvotingAccountBalance(accountsArray[i], voterStartBalance);

      _accounts.push(
        AccountStruct(
          accountsArray[i],
          election.getActiveVotesForGroupByAccount(group, accountsArray[i]),
          election.getPendingVotesForGroupByAccount(group, accountsArray[i]),
          lockedGold.nonvotingAccountBalance(accountsArray[i])
        )
      );
    }
  }

  function makeRandomAction(AccountStruct storage account, uint256 salt) internal {
    VoteActionType[] memory actions = new VoteActionType[](4);
    uint256 actionCount = 0;

    if (account.nonVoting > 0) {
      actions[actionCount++] = VoteActionType.Vote;
    }
    // if (election.hasActivatablePendingVotes(account.account, group)) {
    //   // Assuming this is a view function
    //   actions[actionCount++] = VoteActionType.Activate;
    // }
    if (account.pending > 0) {
      actions[actionCount++] = VoteActionType.RevokePending;
    }
    if (account.active > 0) {
      actions[actionCount++] = VoteActionType.RevokeActive;
    }

    VoteActionType action = actions[generatePRN(0, actionCount - 1, uint256(account.account))];
    uint256 value;

    vm.startPrank(account.account);
    if (action == VoteActionType.Vote) {
      value = generatePRN(0, account.nonVoting, uint256(account.account) + salt);
      election.vote(group, value, address(0), address(0));
      account.nonVoting -= value;
      account.pending += value;
    } else if (action == VoteActionType.Activate) {
      value = account.pending;
      election.activate(group);
      account.pending -= value;
      account.active += value;
    } else if (action == VoteActionType.RevokePending) {
      value = generatePRN(0, account.pending, uint256(account.account) + salt);
      election.revokePending(group, value, address(0), address(0), 0);
      account.pending -= value;
      account.nonVoting += value;
    } else if (action == VoteActionType.RevokeActive) {
      value = generatePRN(0, account.active, uint256(account.account) + salt);
      election.revokeActive(group, value, address(0), address(0), 0);
      account.active -= value;
      account.nonVoting += value;
    }
    vm.stopPrank();
  }

  function checkVoterInvariants(AccountStruct memory account, uint256 delta) public {
    assertAlmostEqual(
      election.getPendingVotesForGroupByAccount(group, account.account),
      account.pending,
      delta
    );
    assertAlmostEqual(
      election.getActiveVotesForGroupByAccount(group, account.account),
      account.active,
      delta
    );
    assertAlmostEqual(
      election.getTotalVotesForGroupByAccount(group, account.account),
      account.active + account.pending,
      delta
    );
    assertAlmostEqual(
      lockedGold.nonvotingAccountBalance(account.account),
      account.nonVoting,
      delta
    );
  }

  function checkGroupInvariants(uint256 delta) public {
    uint256 pendingTotal;

    for (uint256 i = 0; i < _accounts.length; i++) {
      pendingTotal += _accounts[i].pending;
    }

    uint256 activateTotal;

    for (uint256 i = 0; i < _accounts.length; i++) {
      activateTotal += _accounts[i].active;
    }

    assertAlmostEqual(election.getPendingVotesForGroup(group), pendingTotal, delta);
    assertAlmostEqual(election.getActiveVotesForGroup(group), activateTotal, delta);
    assertAlmostEqual(election.getTotalVotesForGroup(group), pendingTotal + activateTotal, delta);

    assertAlmostEqual(election.getTotalVotes(), election.getTotalVotesForGroup(group), delta);
  }

  function revokeAllAndCheckInvariants(uint256 delta) public {
    for (uint256 i = 0; i < _accounts.length; i++) {
      AccountStruct storage account = _accounts[i];

      checkVoterInvariants(account, delta);

      uint256 active = election.getActiveVotesForGroupByAccount(group, account.account);
      if (active > 0) {
        vm.prank(account.account);
        election.revokeActive(group, active, address(0), address(0), 0);
        account.active = 0;
        account.nonVoting += active;
      }

      uint256 pending = account.pending;
      if (pending > 0) {
        vm.prank(account.account);
        election.revokePending(group, pending, address(0), address(0), 0);
        account.pending = 0;
        account.nonVoting += pending;
      }

      assertEq(election.getActiveVotesForGroupByAccount(group, account.account), 0);
      assertEq(election.getPendingVotesForGroupByAccount(group, account.account), 0);
      assertEq(lockedGold.nonvotingAccountBalance(account.account), account.nonVoting);
    }
  }

  // function test_ActualAndExpectedShouldAlwaysMatchExactly_WhenNoEpochRewardsAreDistributed()
  //   public
  // {
  //   for (uint256 i = 0; i < 10; i++) {
  //     for (uint256 j = 0; j < _accounts.length; j++) {
  //       makeRandomAction(_accounts[j], j);
  //       checkVoterInvariants(_accounts[j], 0);
  //       checkGroupInvariants(0);
  //       vm.roll((i + 1) * EPOCH_SIZE + (i + 1));
  //     }
  //   }
  //   revokeAllAndCheckInvariants(0);
  // }

  function distributeEpochRewards(uint256 salt) public {
    // 1% compounded 100x gives up to a 2.7x multiplier.
    uint256 reward = generatePRN(0, election.getTotalVotes() / 100, salt);
    uint256 activeTotal;

    for (uint256 i = 0; i < _accounts.length; i++) {
      activeTotal += _accounts[i].active;
    }

    if (reward > 0 && activeTotal > 0) {
      election.distributeEpochRewards(group, reward, address(0), address(0));

      for (uint256 i = 0; i < _accounts.length; i++) {
        AccountStruct storage account = _accounts[i];
        account.active = ((activeTotal + reward) * _accounts[i].active) / activeTotal;
      }
    }
  }

  // function test_ActualAndExpectedShouldAlwaysMatchWithinSmallDelta_WhenEpochRewardsAreDistributed()
  //   public
  // {
  //   for (uint256 i = 0; i < 30; i++) {
  //     for (uint256 j = 0; j < _accounts.length; j++) {
  //       makeRandomAction(_accounts[j], j);
  //       checkVoterInvariants(_accounts[j], 100);
  //       checkGroupInvariants(100);
  //     }

  //     distributeEpochRewards(i);
  //     vm.roll((i + 1) * EPOCH_SIZE + (i + 1));

  //     for (uint256 j = 0; j < _accounts.length; j++) {
  //       checkVoterInvariants(_accounts[j], 100);
  //       checkGroupInvariants(100);
  //     }
  //   }
  //   revokeAllAndCheckInvariants(100);
  // }

}
