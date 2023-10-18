//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";

// Useful for debugging. Remove when deploying to a live network.
import "hardhat/console.sol";

// Use openzeppelin to inherit battle-tested implementations (ERC20, ERC721, etc)
// import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * is an agreement between
 * trusted friends to contribute funds on a periodic basis to a "pot", and in
 * each round one of the participants receives the pot (termed "winner").
 * The winner is selected using chainlink VRF.
 *
 * Supports ETH and ERC20-compliant tokens.
 * @author David Onyedikachi Anyatonwu
 */
contract AjoDAO is IERC721Receiver {
	using SafeERC20 for IERC20;
	// using PriceConverter for uint256;

	// State Variables
	VRFCoordinatorV2Interface COORDINATOR;
	LinkTokenInterface LINKTOKEN;
	address public i_priceFeedToken;

	// Chainlink PriceFeeds - (token / USD)
	AggregatorV3Interface private immutable i_priceFeedNative;
	AggregatorV3Interface private immutable i_priceFeedUSDC;
	AggregatorV3Interface private immutable i_priceFeedUSDT;
	AggregatorV3Interface private immutable i_priceFeedDAI;
	AggregatorV3Interface private immutable i_priceFeedBTC;

	// Token Addresses
	address private immutable i_NativeAddress;
	address private immutable i_USDCAddress;
	address private immutable i_USDTAddress;
	address private immutable i_DAIAddress;
	address private immutable i_WBTCAddress;
	// constants
	uint256 public constant MAXIMUM_FEE_USD = 50 * 1e18;

	AggregatorV3Interface priceFeed = AggregatorV3Interface(i_priceFeedToken);

	// Chainlink stuff:

	// CHANGE THIS TO POLYGON MUMBAI
	// Sepolia coordinator. For other networks,
	// see https://docs.chain.link/docs/vrf-contracts/#configurations
	address vrfCoordinator = 0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed;

	// Sepolia LINK token contract. For other networks, see
	// https://docs.chain.link/docs/vrf-contracts/#configurations
	address link_token_contract = 0x326C977E6efc84E512bB9C30f76E30c160eD06FB;

	// The gas lane to use, which specifies the maximum gas price to bump to.
	// For a list of available gas lanes on each network,
	// see https://docs.chain.link/docs/vrf-contracts/#configurations
	bytes32 keyHash =
		0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;

	// A reasonable default is 100000, but this value could be different
	// on other networks.
	uint32 callbackGasLimit = 100000;

	// The default is 3, but you can set this higher.
	uint16 requestConfirmations = 3;

	// For this example, retrieve 1 random value in one request.
	// Cannot exceed VRFCoordinatorV2.MAX_NUM_WORDS.
	uint32 numWords = 1;

	// Storage parameters
	uint256[] public s_randomWords;
	uint256 public s_requestId;
	uint64 private s_subscriptionId;

	// AJoData struct
	struct AjoDAOData {
		address token;
		uint256 cycleDuration;
		uint256 contributionAmount;
		uint256 penalty;
		uint256 maxParticipants;
		string name;
		string description;
		address treasury;
		// address owner;
		IERC721 nftContract;
		// IDAOContract daoContract;
		TANDA_STATE t_state;
		uint256 lastUpdateTimestamp;
		// Additional parameters
		address[] contributors;
		mapping(address => uint256) contributorAmounts;
		mapping(uint256 => CycleData) cycleHistory;
		mapping(address => bool) hasPaidPenalty;
	}

	struct CycleData {
		uint256 cycleNumber;
		uint256 cycleStartTime;
		uint256 cycleEndTime;
		address recipient;
		uint256 totalAmount;
	}

	// Fee collection
	uint256 public ServiceFeePurse;
	mapping(address => uint256) public ServiceFeePurseTokenBalances;
	uint256 public AjoDAOPurseBalance;
	mapping(address => uint256) public AjoDAOPurseTokenBalance;
	uint256 public AjoDAOPursePenaltyBalance;
	mapping(address => uint256) public AjoDAOPursePenaltyTokenBalance;

	AjoDAOData public s_ajoDao; // State storage reference

	// Mapping member address to completed cycle count
	mapping(address => uint256) public completedCycles;

	enum TANDA_STATE {
		OPEN,
		CLOSED,
		PAYMENT_IN_PROGRESS,
		COMPLETED
	}

	// Events:
	event CycleClosed(
		uint256 cycleNumber,
		uint256 totalAmount,
		address recipient
	);
	event PaymentStarted(
		uint256 cycleNumber,
		uint256 totalAmount,
		address recipient
	);

	event PenaltyPaid(address indexed member, uint amount);
	event PenaltyFailed(address indexed member, uint amount, string reason);

	// Errors
	/// Function cannot be called at this time.
	error FunctionInvalidAtThisState();

	// Modifiers:
	modifier atState(TANDA_STATE tanda_state_) {
		if (tanda_state != tanda_state_) revert FunctionInvalidAtThisState();
		_;
	}

	modifier penaltyNotPaid() {
		require(
			!s_ajoDao.hasPaidPenalty[msg.sender],
			"Penalty fee already paid"
		);
		_;
	}

	// Curent stage of the contract.
	TANDA_STATE public tanda_state = TANDA_STATE.OPEN;

	constructor(
		address _token,
		uint256 _cycleDuration,
		uint256 _contributionAmount,
		uint256 _penalty,
		uint256 _maxParticipant,
		string memory _name,
		string memory _description
	) {
		require(
			_contributionAmount % 2 == 0,
			"Contribution amount must be divisible by 2"
		);
		require(
			_penalty == _contributionAmount / 2,
			"Penalty must be 50% of contribution"
		);

		COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
		LINKTOKEN = LinkTokenInterface(link_token_contract);
		// Hard code these for now
		i_priceFeedNative = AggregatorV3Interface(
			0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada
		);
		i_priceFeedUSDC = AggregatorV3Interface(
			0x572dDec9087154dC5dfBB1546Bb62713147e0Ab0
		);
		i_priceFeedUSDT = AggregatorV3Interface(
			0x92C09849638959196E976289418e5973CC96d645
		);
		i_priceFeedDAI = AggregatorV3Interface(
			0x0FCAa9c899EC5A91eBc3D5Dd869De833b06fB046
		);
		i_priceFeedBTC = AggregatorV3Interface(
			0x007A22900a3B98143368Bd5906f8E17e9867581b
		);

		i_NativeAddress = address(0x0000000000000000000000000000000000000000);
		i_USDCAddress = address(0x0FA8781a83E46826621b3BC094Ea2A0212e71B23);
		i_USDTAddress = address(0xA02f6adc7926efeBBd59Fd43A84f4E0c0c91e832);
		i_DAIAddress = address(0x001B3B4d0F3714Ca98ba10F6042DaEbF0B1B7b6F);
		i_WBTCAddress = address(0x0d787a4a1548f673ed375445535a6c7A1EE56180);

		s_ajoDao.token = _token;
		s_ajoDao.cycleDuration = _cycleDuration;
		s_ajoDao.contributionAmount = _contributionAmount;
		s_ajoDao.penalty = _penalty;
		s_ajoDao.maxParticipants = _maxParticipant;
		s_ajoDao.name = _name;
		s_ajoDao.description = _description;
		s_ajoDao.t_state = TANDA_STATE.OPEN;
		s_ajoDao.lastUpdateTimestamp = block.timestamp;

		setPriceFeedToken(_token);
	}

	function payPenaltyFee(
		address _tokenAddress,
		uint256 _tokenAmount
	) external payable atState(TANDA_STATE.OPEN) penaltyNotPaid {
		AjoDAOData storage s = s_ajoDao;
		require(
			isValidToken(_tokenAddress),
			"Invalid Token, confirm pot details for accepted token"
		);

		if (_tokenAddress == address(0)) {
			require(msg.value == s.penalty, "Incorrect penalty fee amount");

			AjoDAOPursePenaltyBalance += msg.value;

			emit PenaltyPaid(msg.sender, msg.value);
		} else {
			require(
				_tokenAmount == s.penalty,
				"Incorrect token amount for penalty fee"
			);

			IERC20(_tokenAddress).safeTransferFrom(
				msg.sender,
				address(this),
				_tokenAmount
			);

			emit PenaltyPaid(msg.sender, _tokenAmount);

			AjoDAOPursePenaltyTokenBalance[_tokenAddress] += _tokenAmount;
		}

		s.hasPaidPenalty[msg.sender] = true;
	}

	/**
	 * Function that allows the contract to receive ETH
	 */
	receive() external payable {}

	function setPriceFeedToken(address _token) internal {
		if (_token == i_USDCAddress) {
			i_priceFeedToken = i_USDCAddress;
		} else if (_token == i_USDTAddress) {
			i_priceFeedToken = i_USDTAddress;
		} else if (_token == i_DAIAddress) {
			i_priceFeedToken = i_DAIAddress;
		} else if (_token == i_WBTCAddress) {
			i_priceFeedToken = i_WBTCAddress;
		} else if (_token == i_NativeAddress) {
			i_priceFeedToken = i_NativeAddress;
		} else {
			// Handle the case where the token address is not valid
			revert("Invalid token address");
		}
	}

	function isValidToken(address _token) internal returns (bool) {
		return (_token == address(s_ajoDao.token));
	}

	function onERC721Received(
		address operator,
		address from,
		uint256 tokenId,
		bytes calldata data
	) external override returns (bytes4) {
		return this.onERC721Received.selector;
	}
}
