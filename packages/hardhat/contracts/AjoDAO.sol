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
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";

import "./PriceConverter.sol";

// Useful for debugging. Remove when deploying to a live network.
import "hardhat/console.sol";

// Use openzeppelin to inherit battle-tested implementations (ERC20, ERC721, etc)
// import "@openzeppelin/contracts/access/Ownable.sol";

interface IPUSHCommInterface {
	function sendNotification(
		address _channel,
		address _recipient,
		bytes calldata _identity
	) external;
}

/**
 * is an agreement between
 * trusted friends to contribute funds on a periodic basis to a "pot", and in
 * each round one of the participants receives the pot (termed "winner").
 * The winner is selected using chainlink VRF.
 *
 * Supports ETH and ERC20-compliant tokens.
 * @author David Onyedikachi Anyatonwu
 */
contract AjoDAO is
	IERC721Receiver,
	AutomationCompatibleInterface,
	VRFV2WrapperConsumerBase
{
	using SafeERC20 for IERC20;
	using PriceConverter for uint256;

	// State Variables
	VRFCoordinatorV2Interface COORDINATOR;
	LinkTokenInterface LINKTOKEN;
	address public i_priceFeedToken;
	uint256 contributedCount;
	uint256 paidParticipants;

	address public EPNS_COMM_ADDRESS =
		0xb3971BCef2D791bc4027BbfedFb47319A4AAaaAa;

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
		mapping(uint256 => CycleData) cycleHistory; // Timestamp -> CycleData
		mapping(address => bool) hasPaidPenalty;
	}

	struct CycleData {
		uint256 cycleNumber;
		uint256 cycleStartTime;
		uint256 cycleEndTime;
		address recipient;
		uint256 totalAmount;
	}

	mapping(address => bool) public isParticipant;
	mapping(address => bool) public hasContributed;

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
		COMPLETED,
		CONTRIBUTING
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

	event PenaltyPaid(address indexed member, uint256 amount);
	event PenaltyFailed(address indexed member, uint256 amount, string reason);

	event ParticipantJoined(address indexed participant);
	event StateChanged(TANDA_STATE newState);
	event ParticipantContributed(address indexed, uint256 amount);
	event AjoPotWinner(address potWinner, uint256 amount);

	// Errors
	/// Function cannot be called at this time.
	error FunctionInvalidAtThisState();
	error InsufficientFunds(uint256 balance, uint256 paid);
	error TransferFailed();

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
		string memory _description,
		address _linkAddress,
		address _wrapperAddress
	) VRFV2WrapperConsumerBase(_linkAddress, _wrapperAddress) {
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
	) external payable atState(TANDA_STATE.OPEN) {
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

		pushNotification(
			msg.sender,
			"Penalty Fee Paid",
			"Your penalty fee has been paid."
		);
	}

	function joinAjoClub(
		address _token,
		uint256 _contributionAmount
	) external payable atState(TANDA_STATE.OPEN) penaltyNotPaid {
		AjoDAOData storage s = s_ajoDao;
		require(
			s.maxParticipants != s.contributors.length,
			"Maximum participants reached, Pot can't accept any more members"
		);
		require(s.hasPaidPenalty[msg.sender], "Penalty fee not paid");

		require(!isParticipant[msg.sender], "Already a participant");
		require(
			isValidToken(_token),
			"Invalid Token, confirm pot details for accepted token"
		);

		if (_token == address(0)) {
			require(
				msg.value == s.contributionAmount + MAXIMUM_FEE_USD,
				"Incorrect amount"
			);

			// Calculating fee for ether payment
			uint256 serviceFee;
			if (msg.value / 200 > MAXIMUM_FEE_USD) {
				serviceFee = MAXIMUM_FEE_USD.getConversionRate(
					i_priceFeedNative
				);
			} else {
				serviceFee = msg.value / 200;
			}
			ServiceFeePurse += serviceFee;
			AjoDAOPurseBalance += (msg.value - serviceFee);
			s.contributors.push(msg.sender);
			isParticipant[msg.sender] = true;
		} else {
			require(msg.value == 0, "Invalid Ether value");
			require(
				_contributionAmount > s.contributionAmount,
				"Invalid token amount"
			);
			require(_token == s.token, "Invalid token");
			// Calculating fee for ether payment
			uint256 serviceFee;
			if (_contributionAmount / 200 > MAXIMUM_FEE_USD) {
				serviceFee = MAXIMUM_FEE_USD.getConversionRate(
					i_priceFeedNative
				);
			} else {
				serviceFee = _contributionAmount / 200;

				ServiceFeePurseTokenBalances[_token] += serviceFee;

				IERC20(_token).safeTransferFrom(
					msg.sender,
					address(this),
					_contributionAmount
				);

				AjoDAOPurseTokenBalance[_token] += (_contributionAmount -
					serviceFee);
				s.contributors.push(msg.sender);
				isParticipant[msg.sender] = true;
			}

			pushNotification(
				msg.sender,
				"Joined Ajo Club",
				"You have successfully joined the Ajo Club."
			);
		}
		// Emit someone joined
		emit ParticipantJoined(msg.sender);

		// Change state when the maxParticipant is reached
		if (s.maxParticipants == s.contributors.length) {
			s.t_state = TANDA_STATE.PAYMENT_IN_PROGRESS;
		}

		// Emit change of state
		emit StateChanged(s.t_state);
	}

	// Make contribution
	function contribute(uint256 _amount) external payable {
		AjoDAOData storage s = s_ajoDao;
		// Check that the user is participant
		require(
			isParticipant[msg.sender],
			"You must join club before contributing"
		);
		require(s.t_state == TANDA_STATE.CONTRIBUTING, "Wrong state");

		require(_amount == s.contributionAmount, "Wrong amount");

		// Check allowance, even for those functions above.

		if (s.token == address(0)) {
			require(msg.value == s.contributionAmount, "Wrong amount");
			AjoDAOPurseBalance += msg.value;
		} else {
			require(_amount == s.contributionAmount, "Wrong amount");
			IERC20(s.token).safeTransferFrom(
				msg.sender,
				address(this),
				_amount
			);

			AjoDAOPurseTokenBalance[s.token] += _amount;
		}

		emit ParticipantContributed(msg.sender, _amount);
		contributedCount++;

		pushNotification(
			msg.sender,
			"Contribution Received",
			"Your contribution has been received."
		);

		if (contributedCount == s.maxParticipants) {
			s.t_state = TANDA_STATE.PAYMENT_IN_PROGRESS;
		}
	}

	function checkUpkeep(
		bytes memory checkData
	)
		public
		view
		override
		returns (bool upkeepNeeded, bytes memory performData)
	{
		AjoDAOData storage s = s_ajoDao;

		require(s.cycleDuration > 0, "Invalid cycle duration");

		if (
			s.t_state == TANDA_STATE.PAYMENT_IN_PROGRESS &&
			block.timestamp >= s.lastUpdateTimestamp + s.cycleDuration
		) {
			return (true, "");
		} else {
			return (false, "");
		}
	}

	function performUpkeep(bytes calldata _performData) external {
		AjoDAOData storage s = s_ajoDao;

		if (
			s.t_state == TANDA_STATE.PAYMENT_IN_PROGRESS &&
			block.timestamp >= s.lastUpdateTimestamp + s.cycleDuration
		) {
			// 		  requestRandomWords();
		}
	}

	function requestRandomWords(
		uint32 _callbackGaslimit,
		uint16 _requestConfirmations,
		uint32 _numWords
	) external returns (uint256 requestId) {
		requestId = requestRandomness(
			_callbackGaslimit,
			_requestConfirmations,
			_numWords
		);
		uint256 paid = VRF_V2_WRAPPER.calculateRequestPrice(_callbackGaslimit);
		uint256 balance = LINK.balanceOf(address(this));
		if (balance < paid) revert InsufficientFunds(balance, paid);
		return requestId;
	}

	function fulfillRandomWords(
		uint256 _requestId,
		uint256[] memory _randomWords
	) internal override {
		AjoDAOData storage s = s_ajoDao;
		s_randomWords = _randomWords;
		uint256 potWinnerIndex = s_randomWords[0] % s.contributors.length;
		address potWinner = s.contributors[potWinnerIndex];

		if (
			AjoDAOPurseBalance >= s.contributionAmount * s.contributors.length
		) {
			(bool success, ) = potWinner.call{ value: AjoDAOPurseBalance }("");
			if (!success) {
				revert TransferFailed();
			}
			emit AjoPotWinner(potWinner, AjoDAOPurseBalance);
			AjoDAOPurseBalance = 0;
		} else if (
			AjoDAOPursePenaltyTokenBalance[s.token] >=
			s.contributionAmount * s.contributors.length
		) {
			address payable tokenAddress = payable(s.token);
			bool success = IERC20(tokenAddress).transfer(
				potWinner,
				AjoDAOPursePenaltyTokenBalance[s.token]
			);
			if (!success) {
				revert TransferFailed();
			}
			emit AjoPotWinner(potWinner, AjoDAOPurseBalance);

			pushNotification(
				potWinner,
				"Pot winner",
				"You won the pot for this Ajo round"
			);
		}

		paidParticipants++;
		if (paidParticipants == s.maxParticipants) {
			s.t_state = TANDA_STATE.CLOSED;
		} else {
			s.t_state = TANDA_STATE.OPEN;
		}
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

	function pushNotification(
		address to,
		string memory title,
		string memory body
	) internal {
		IPUSHCommInterface(EPNS_COMM_ADDRESS).sendNotification(
			0x050Ca75E3957c37dDF26D58046d8F9967B88190c, // from channel
			to, // to recipient
			bytes(
				string(
					abi.encodePacked(
						"0", // notification identity
						"+", // segregator
						"3", // payload type
						"+", // segregator
						title, // notification title
						"+", // segregator
						body // notification body
					)
				)
			)
		);
	}
}
