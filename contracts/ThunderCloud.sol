pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./StormToken.sol";

// ThunderCloud is the hub that accumulates and distributes STORM
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once STORM is sufficiently
// distributed and the community can show to govern itself.
//
contract ThunderCloud is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        address ref; // Ref address
        //
        // We do some fancy math here. Basically, any point in time, the amount of STORMs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accStormPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accStormPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. STORMs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that STORMs distribution occurs.
        uint256 accStormPerShare; // Accumulated STORMs per share, times 1e12. See below.
    }

    // The STORM TOKEN!
    StormToken public storm;
    // Dev address.
    address public devaddr;
    // Block number when bonus STORM period ends.
    uint256 public bonusEndBlock;
    // STORM tokens created per block.
    uint256 public stormPerBlock;
    // Bonus muliplier for early storm makers.
    uint256 public constant BONUS_MULTIPLIER = 100;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when STORM mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    constructor(
        StormToken _storm,
        address _devaddr,
        uint256 _stormPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        storm = _storm;
        devaddr = _devaddr;
        stormPerBlock = _stormPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function changeStormPerBlock(uint256 _newStormPerBlock) public onlyOwner {
        stormPerBlock = _newStormPerBlock;
    }

    // Detects whether the given pool already exists
    function checkPoolDuplicate(IERC20 _lpToken) public {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: existing pool");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_lpToken);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accStormPerShare: 0
        }));
    }

    // Update the given pool's STORM allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner validatePool(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending STORMs on frontend.
    function pendingStorm(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accStormPerShare = pool.accStormPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 stormReward = multiplier.mul(stormPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accStormPerShare = accStormPerShare.add(stormReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accStormPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 stormReward = multiplier.mul(stormPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        storm.mint(devaddr, stormReward.div(6));
        storm.mint(address(this), stormReward);
        pool.accStormPerShare = pool.accStormPerShare.add(stormReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to ThunderCloud for STORM allocation.
    function deposit(uint256 _pid, uint256 _amount, address _ref) public validatePool(_pid) {
        require(_ref != msg.sender, "deposit: invalid ref address");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accStormPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeStormTransfer(msg.sender, pending);
            }

            if (user.ref != address(0)) {
                storm.mint(user.ref, pending.div(20));
                storm.mint(msg.sender, pending.div(20));
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accStormPerShare).div(1e12);
        
        if (_ref != address(0)) {
            user.ref = _ref;
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from ThunderCloud.
    function withdraw(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accStormPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeStormTransfer(msg.sender, pending);

            if (user.ref != address(0)) {
                storm.mint(user.ref, pending.div(10));
            }
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accStormPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe storm transfer function, just in case if rounding error causes pool to not have enough STORMs.
    function safeStormTransfer(address _to, uint256 _amount) internal {
        uint256 stormBal = storm.balanceOf(address(this));
        if (_amount > stormBal) {
            storm.transfer(_to, stormBal);
        } else {
            storm.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
