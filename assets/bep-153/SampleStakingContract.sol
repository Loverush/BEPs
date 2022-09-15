pragma solidity 0.8.16;

interface IStaking {

  function delegate(address validator, uint256 amount) external payable;

  function undelegate(address validator, uint256 amount) external payable;

  function redelegate(address validatorSrc, address validatorDst, uint256 amount) external payable;

  function claimReward() external returns(uint256);

  function claimUndelegated() external returns(uint256);

  function getDelegated(address delegator, address validator) external view returns(uint256);

  function getTotalDelegated(address delegator) external view returns(uint256);

  function getDistributedReward(address delegator) external view returns(uint256);

  function getPendingRedelegateTime(address delegator, address valSrc, address valDst)  external view returns(uint256);

  function getUndelegated(address delegator) external view returns(uint256);

  function getPendingUndelegateTime(address delegator, address validator) external view returns(uint256);

  function getRelayerFee() external view returns(uint256);

  function getMinDelegation() external view returns(uint256);

  function getRequestInFly(address delegator) external view returns(uint256[3] memory);
}

contract StakingDappExample {
  uint8 internal locked;

  // constants
  uint256 public constant LOCK_TIME = 8 days;
  uint256 public constant TEN_DECIMALS = 1e10;
  address public constant STAKING_CONTRACT_ADDR = 0x0000000000000000000000000000000000002001;

  // data struct
  struct PoolInfo {
    uint256 rewardPerShare;
    uint256 lastRewardBlock;
    uint256 lastTotalReward;
  }

  struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
    bool minusDebt;
    uint256 pendingUndelegated;
    uint256 undelegateUnlockTime;
  }

  // global variables
  address public owner;
  uint256 public totalReceived;
  uint256 public totalStaked;
  uint256 public totalReward;
  uint256 public reserveReward;
  uint256 public reserveUndelegated;

  PoolInfo internal poolInfo;
  mapping(address => UserInfo) internal userInfo;
  mapping(address => bool) internal operators;

  // modifiers
  modifier onlyOwner() {
    require(msg.sender == owner, "only owner can call this function");
    _;
  }

  modifier onlyOperator() {
    require(operators[msg.sender], "only operator can call this function");
    _;
  }

  modifier noReentrant() {
    require(locked != 2, "No re-entrancy");
    locked = 2;
    _;
    locked = 1;
  }

  // events
  event Delegate(address indexed delegator, uint256 amount);
  event DelegateSubmitted(address indexed validator, uint256 amount);
  event Undelegate(address indexed delegator, uint256 amount);
  event UndelegateSubmitted(address indexed validator, uint256 amount);
  event RewardClaimed(address indexed delegator, uint256 amount);
  event UndelegatedClaimed(address indexed delegator, uint256 amount);
  event RewardReceived(uint256 amount);
  event UndelegatedReceived(uint256 amount);
  event AddOperator(address indexed newOperator);
  event DelOperator(address indexed operator);
  event TransferOwnership(address indexed newOwner);

  receive() external payable {}

  constructor() {
    owner = msg.sender;
    operators[msg.sender] = true;
  }

  /*********************** For user **************************/
  // This function will not submit delegation request to the staking system contract.
  // The delegation should be called by operators manually as the proper validator need to be determined.
  // Delegate and undelegate will also trigger claimReward.
  function delegate() external payable {
    uint256 amount = msg.value;

    // update reward first
    UserInfo storage user = userInfo[msg.sender];
    _updatePool();
    uint256 pendingReward;
    if (user.amount != 0) {
      pendingReward = user.amount*poolInfo.rewardPerShare-user.rewardDebt;
    }
    user.amount = user.amount+amount;
    user.rewardDebt = user.amount*poolInfo.rewardPerShare;

    totalReceived = totalReceived+amount;
    reserveUndelegated = reserveUndelegated+amount;

    if (pendingReward != 0) {
      payable(msg.sender).transfer(pendingReward);
    }
    emit Delegate(msg.sender, amount);
  }

  // This function will not submit undelegation request to the staking system contract.
  // The undelegation should be called by operators manually as the proper validator need to be determined.
  // Delegate and undelegate will also trigger claimReward.
  function undelegate(uint256 amount) external {
    UserInfo storage user = userInfo[msg.sender];
    require(user.amount >= amount, "insufficient balance");

    // update reward first
    _updatePool();
    uint256 pendingReward = user.amount*poolInfo.rewardPerShare-user.rewardDebt;
    user.amount  = user.amount-amount;
    user.rewardDebt = user.amount*poolInfo.rewardPerShare;

    user.pendingUndelegated = user.pendingUndelegated+amount;
    user.undelegateUnlockTime = block.timestamp+LOCK_TIME;

    totalReceived = totalReceived-amount;
    payable(msg.sender).transfer(pendingReward);
    emit Undelegate(msg.sender, amount);
  }

  function getDelegated(address delegator) external view returns(uint256) {
    return userInfo[delegator].amount;
  }

  function claimReward() external noReentrant {
    UserInfo storage user = userInfo[msg.sender];
    require(user.amount != 0, "no delegation");

    _updatePool();
    uint256 pendingReward = user.amount*poolInfo.rewardPerShare-user.rewardDebt;
    if (reserveReward < pendingReward) {
      _claimReward();
    }
    user.rewardDebt = user.amount*poolInfo.rewardPerShare;
    reserveReward -= pendingReward;
    payable(msg.sender).transfer(pendingReward);
    emit RewardClaimed(msg.sender, pendingReward);
  }

  function claimUndelegated() external noReentrant {
    UserInfo storage user = userInfo[msg.sender];
    require((user.pendingUndelegated != 0) && (block.timestamp > user.undelegateUnlockTime), "no undelegated funds");

    if (reserveUndelegated < user.pendingUndelegated) {
      _claimUndelegated();
    }
    reserveUndelegated = reserveUndelegated-user.pendingUndelegated;
    totalReceived = totalReceived-user.pendingUndelegated;
    uint256 amount = user.pendingUndelegated;
    user.pendingUndelegated = 0;
    payable(msg.sender).transfer(amount);
    emit UndelegatedClaimed(msg.sender, user.pendingUndelegated);
  }

  function getPendingReward(address delegator) external view returns(uint256 pendingReward) {
    UserInfo memory user = userInfo[delegator];
    pendingReward = user.amount*poolInfo.rewardPerShare-user.rewardDebt;
  }

  function _delegate(address validator, uint256 amount, uint256 relayerFee) public payable {
    require(amount%TEN_DECIMALS == 0, "precision loss");
    require(address(this).balance >= relayerFee, "insufficient funds");
    IStaking(STAKING_CONTRACT_ADDR).delegate{value: amount+relayerFee}(validator, amount);

    totalStaked = totalStaked+amount;
    reserveUndelegated = reserveUndelegated-amount;
    emit DelegateSubmitted(validator, amount);
  }

  function _undelegate(address validator, uint256 amount, uint256 relayerFee) public payable {
    require(amount%TEN_DECIMALS == 0, "precision loss");
    require(address(this).balance >= relayerFee, "insufficient funds");
    IStaking(STAKING_CONTRACT_ADDR).undelegate{value: relayerFee}(validator, amount);

    totalStaked = totalStaked-amount;
    reserveUndelegated = reserveUndelegated+amount;
    emit UndelegateSubmitted(validator, amount);
  }

  function _claimReward() internal {
    uint256 amount = IStaking(STAKING_CONTRACT_ADDR).claimReward();
    totalReward = totalReward+amount;
    reserveReward = reserveReward+amount;
    emit RewardReceived(amount);
  }

  function _claimUndelegated() internal {
    uint256 amount = IStaking(STAKING_CONTRACT_ADDR).claimUndelegated();
    emit UndelegatedReceived(amount);
  }

  function _updatePool() internal {
    if (block.number <= poolInfo.lastRewardBlock) {
      return;
    }
    if (totalReward == poolInfo.lastTotalReward) {
      return;
    }
    uint256 newReward = totalReward - poolInfo.lastTotalReward;
    poolInfo.lastTotalReward = totalReward;
    poolInfo.rewardPerShare = poolInfo.rewardPerShare+newReward/totalStaked;
    poolInfo.lastRewardBlock = block.number;
  }

  /*********************** Handle faliure **************************/
  // This parts of functions should be called by the operator when failed event detected by the monitor
  function handleFailedDelegate(address validator, uint256 amount) external onlyOperator {
    totalStaked = totalStaked-amount;
    reserveUndelegated = reserveUndelegated+amount;

    amount = IStaking(STAKING_CONTRACT_ADDR).claimUndelegated();
    uint256 relayerFee = IStaking(STAKING_CONTRACT_ADDR).getRelayerFee();
    amount -= amount%TEN_DECIMALS;
    require(address(this).balance > amount+relayerFee, "insufficient balance");
    _delegate(validator, amount, relayerFee);
    totalStaked = totalStaked+amount;
    reserveUndelegated = reserveUndelegated-amount;
  }

  function handleFailedUndelegate(address validator, uint256 amount) external onlyOperator {
    totalStaked = totalStaked+amount;
    reserveUndelegated = reserveUndelegated-amount;

    uint256 relayerFee = IStaking(STAKING_CONTRACT_ADDR).getRelayerFee();
    amount -= amount%TEN_DECIMALS;
    require(address(this).balance > relayerFee, "insufficient balance");
    _undelegate(validator, amount, relayerFee);
    totalStaked = totalStaked-amount;
    reserveUndelegated = reserveUndelegated+amount;
  }

  /*********************** Params update **************************/
  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "invalid address");
    owner = newOwner;
    emit TransferOwnership(newOwner);
  }

  function addOperator(address opt) external onlyOwner {
    require(opt != address(0), "invalid address");
    operators[opt] = true;
    emit AddOperator(opt);
  }

  function delOperator(address opt) external onlyOwner {
    operators[opt] = false;
    emit DelOperator(opt);
  }
}
