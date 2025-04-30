// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title DecentralizedExpenseSplitter
 * @dev Smart contract for tracking shared expenses and settling balances between groups
 */
contract DecentralizedExpenseSplitter {
    
    // Group structure
    struct Group {
        string name;
        address[] members;
        bool active;
        uint256 createdAt;
        mapping(address => bool) isMember;
    }
    
    // Expense structure
    struct Expense {
        uint256 id;
        string description;
        uint256 amount;
        address paidBy;
        uint256 date;
        address[] splitAmong;
        bool settled;
    }
    
    // Settlement structure
    struct Settlement {
        address payer;
        address receiver;
        uint256 amount;
        bool completed;
        uint256 settledAt;
    }
    
    // Storage
    uint256 private groupCounter;
    uint256 private expenseCounter;
    uint256 private settlementCounter;
    
    // Mappings
    mapping(uint256 => Group) public groups;
    mapping(uint256 => Expense) public expenses;
    mapping(uint256 => mapping(uint256 => bool)) public groupExpenses; // groupId => expenseId => exists
    mapping(uint256 => Settlement) public settlements;
    mapping(uint256 => mapping(address => mapping(address => int256))) public balances; // groupId => from => to => amount
    mapping(address => uint256[]) public userGroups;
    
    // Events
    event GroupCreated(uint256 indexed groupId, string name, address creator, uint256 timestamp);
    event MemberAdded(uint256 indexed groupId, address member, uint256 timestamp);
    event MemberRemoved(uint256 indexed groupId, address member, uint256 timestamp);
    event ExpenseAdded(uint256 indexed groupId, uint256 indexed expenseId, address paidBy, uint256 amount, uint256 timestamp);
    event ExpenseSettled(uint256 indexed expenseId, uint256 timestamp);
    event SettlementCreated(uint256 indexed settlementId, uint256 indexed groupId, address payer, address receiver, uint256 amount, uint256 timestamp);
    event SettlementCompleted(uint256 indexed settlementId, uint256 timestamp);
    event BalanceUpdated(uint256 indexed groupId, address from, address to, int256 amount);
    
    /**
     * @dev Create a new expense sharing group
     * @param _name Name of the group
     * @param _members Initial members of the group
     * @return groupId The ID of the newly created group
     */
    function createGroup(string memory _name, address[] memory _members) public returns (uint256 groupId) {
        require(bytes(_name).length > 0, "Group name cannot be empty");
        
        groupId = ++groupCounter;
        Group storage newGroup = groups[groupId];
        newGroup.name = _name;
        newGroup.active = true;
        newGroup.createdAt = block.timestamp;
        
        // Add creator as a member
        newGroup.members.push(msg.sender);
        newGroup.isMember[msg.sender] = true;
        userGroups[msg.sender].push(groupId);
        
        // Add other members
        for (uint256 i = 0; i < _members.length; i++) {
            address member = _members[i];
            if (member != msg.sender && !newGroup.isMember[member]) {
                newGroup.members.push(member);
                newGroup.isMember[member] = true;
                userGroups[member].push(groupId);
            }
        }
        
        emit GroupCreated(groupId, _name, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Add a member to an existing group
     * @param _groupId ID of the group
     * @param _member Address of the member to add
     */
    function addMember(uint256 _groupId, address _member) public {
        require(_groupId <= groupCounter, "Group does not exist");
        require(groups[_groupId].active, "Group is not active");
        require(groups[_groupId].isMember[msg.sender], "Only members can add new members");
        require(!groups[_groupId].isMember[_member], "Member already exists");
        
        groups[_groupId].members.push(_member);
        groups[_groupId].isMember[_member] = true;
        userGroups[_member].push(_groupId);
        
        emit MemberAdded(_groupId, _member, block.timestamp);
    }
    
    /**
     * @dev Remove a member from a group
     * @param _groupId ID of the group
     * @param _member Address of the member to remove
     */
    function removeMember(uint256 _groupId, address _member) public {
        require(_groupId <= groupCounter, "Group does not exist");
        require(groups[_groupId].active, "Group is not active");
        require(groups[_groupId].isMember[msg.sender], "Only members can remove members");
        require(groups[_groupId].isMember[_member], "Member does not exist in group");
        
        // Check that member has no outstanding balances
        Group storage group = groups[_groupId];
        for (uint256 i = 0; i < group.members.length; i++) {
            address otherMember = group.members[i];
            require(
                balances[_groupId][_member][otherMember] == 0 && 
                balances[_groupId][otherMember][_member] == 0,
                "Member has outstanding balances"
            );
        }
        
        // Remove member from array
        for (uint256 i = 0; i < group.members.length; i++) {
            if (group.members[i] == _member) {
                // Replace with last element and pop
                group.members[i] = group.members[group.members.length - 1];
                group.members.pop();
                break;
            }
        }
        
        // Update mapping
        group.isMember[_member] = false;
        
        // Remove group from user's groups
        for (uint256 i = 0; i < userGroups[_member].length; i++) {
            if (userGroups[_member][i] == _groupId) {
                // Replace with last element and pop
                userGroups[_member][i] = userGroups[_member][userGroups[_member].length - 1];
                userGroups[_member].pop();
                break;
            }
        }
        
        emit MemberRemoved(_groupId, _member, block.timestamp);
    }
    
    /**
     * @dev Add a new expense to a group
     * @param _groupId ID of the group
     * @param _description Description of the expense
     * @param _amount Amount spent in wei
     * @param _splitAmong Addresses to split the expense among (can be a subset of group members)
     * @return expenseId The ID of the newly created expense
     */
    function addExpense(
        uint256 _groupId,
        string memory _description,
        uint256 _amount,
        address[] memory _splitAmong
    ) 
        public 
        returns (uint256 expenseId) 
    {
        require(_groupId <= groupCounter, "Group does not exist");
        require(groups[_groupId].active, "Group is not active");
        require(groups[_groupId].isMember[msg.sender], "Only members can add expenses");
        require(_amount > 0, "Amount must be greater than zero");
        require(_splitAmong.length > 0, "Must split among at least one person");
        
        // Validate that all _splitAmong addresses are group members
        for (uint256 i = 0; i < _splitAmong.length; i++) {
            require(groups[_groupId].isMember[_splitAmong[i]], "Split address is not a group member");
        }
        
        // Create new expense
        expenseId = ++expenseCounter;
        Expense storage newExpense = expenses[expenseId];
        newExpense.id = expenseId;
        newExpense.description = _description;
        newExpense.amount = _amount;
        newExpense.paidBy = msg.sender;
        newExpense.date = block.timestamp;
        newExpense.splitAmong = _splitAmong;
        newExpense.settled = false;
        
        // Link expense to group
        groupExpenses[_groupId][expenseId] = true;
        
        // Calculate each person's share
        uint256 sharePerPerson = _amount / _splitAmong.length;
        
        // Update balances
        for (uint256 i = 0; i < _splitAmong.length; i++) {
            address debtor = _splitAmong[i];
            
            // Skip if the payer is also in the split list
            if (debtor == msg.sender) continue;
            
            // Update balances (positive means owed to, negative means owes)
            balances[_groupId][debtor][msg.sender] -= int256(sharePerPerson);
            balances[_groupId][msg.sender][debtor] += int256(sharePerPerson);
            
            emit BalanceUpdated(_groupId, debtor, msg.sender, int256(sharePerPerson));
        }
        
        emit ExpenseAdded(_groupId, expenseId, msg.sender, _amount, block.timestamp);
        
        return expenseId;
    }
    
    /**
     * @dev Create a settlement between two members
     * @param _groupId ID of the group
     * @param _receiver Address that will receive the payment
     * @return settlementId The ID of the newly created settlement
     */
    function createSettlement(uint256 _groupId, address _receiver) public returns (uint256 settlementId) {
        require(_groupId <= groupCounter, "Group does not exist");
        require(groups[_groupId].active, "Group is not active");
        require(groups[_groupId].isMember[msg.sender], "Only members can create settlements");
        require(groups[_groupId].isMember[_receiver], "Receiver is not a group member");
        
        // Get the amount owed
        int256 amountOwed = balances[_groupId][msg.sender][_receiver];
        require(amountOwed > 0, "No debt to settle");
        
        // Create settlement
        settlementId = ++settlementCounter;
        Settlement storage newSettlement = settlements[settlementId];
        newSettlement.payer = msg.sender;
        newSettlement.receiver = _receiver;
        newSettlement.amount = uint256(amountOwed);
        newSettlement.completed = false;
        
        emit SettlementCreated(settlementId, _groupId, msg.sender, _receiver, uint256(amountOwed), block.timestamp);
        
        return settlementId;
    }
    
    /**
     * @dev Complete a settlement (must be called by the payer)
     * @param _settlementId ID of the settlement
     * @param _groupId ID of the group
     */
    function completeSettlement(uint256 _settlementId, uint256 _groupId) public payable {
        require(_settlementId <= settlementCounter, "Settlement does not exist");
        require(_groupId <= groupCounter, "Group does not exist");
        require(groups[_groupId].active, "Group is not active");
        
        Settlement storage settlement = settlements[_settlementId];
        
        require(settlement.payer == msg.sender, "Only payer can complete settlement");
        require(!settlement.completed, "Settlement already completed");
        require(msg.value == settlement.amount, "Incorrect payment amount");
        
        // Update balances
        address receiver = settlement.receiver;
        uint256 amount = settlement.amount;
        
        balances[_groupId][msg.sender][receiver] -= int256(amount);
        balances[_groupId][receiver][msg.sender] += int256(amount);
        
        emit BalanceUpdated(_groupId, msg.sender, receiver, -int256(amount));
        
        // Mark settlement as completed
        settlement.completed = true;
        settlement.settledAt = block.timestamp;
        
        // Transfer funds
        payable(receiver).transfer(amount);
        
        emit SettlementCompleted(_settlementId, block.timestamp);
    }
    
    /**
     * @dev Get all members of a group
     * @param _groupId ID of the group
     * @return Array of member addresses
     */
    function getGroupMembers(uint256 _groupId) public view returns (address[] memory) {
        require(_groupId <= groupCounter, "Group does not exist");
        return groups[_groupId].members;
    }
    
    /**
     * @dev Get all groups a user is a member of
     * @param _user Address to check
     * @return Array of group IDs
     */
    function getUserGroups(address _user) public view returns (uint256[] memory) {
        return userGroups[_user];
    }
    
    /**
     * @dev Check if a specific expense belongs to a group
     * @param _groupId ID of the group
     * @param _expenseId ID of the expense
     * @return True if expense belongs to group
     */
    function isGroupExpense(uint256 _groupId, uint256 _expenseId) public view returns (bool) {
        return groupExpenses[_groupId][_expenseId];
    }
    
    /**
     * @dev Get the balance between two members in a group
     * @param _groupId ID of the group
     * @param _from First member
     * @param _to Second member
     * @return The balance (positive if _from owes _to, negative if _to owes _from)
     */
    function getBalance(uint256 _groupId, address _from, address _to) public view returns (int256) {
        return balances[_groupId][_from][_to];
    }
    
    /**
     * @dev Get details of an expense
     * @param _expenseId ID of the expense
     * @return Description of the expense
     * @return Amount of the expense
     * @return Address that paid the expense
     * @return Date of the expense
     * @return Addresses the expense was split among
     * @return Whether the expense is settled
     */
    function getExpenseDetails(uint256 _expenseId) public view returns (
        string memory,
        uint256,
        address,
        uint256,
        address[] memory,
        bool
    ) {
        require(_expenseId <= expenseCounter, "Expense does not exist");
        Expense storage expense = expenses[_expenseId];
        
        return (
            expense.description,
            expense.amount,
            expense.paidBy,
            expense.date,
            expense.splitAmong,
            expense.settled
        );
    }
}