export const StrategyEngineAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "admin",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spreadOracle_",
        "type": "address",
        "internalType": "contract ISpreadOracle"
      },
      {
        "name": "clock_",
        "type": "address",
        "internalType": "contract IMarketClock"
      },
      {
        "name": "defaults",
        "type": "tuple",
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "DEFAULT_ADMIN_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXIT_BORROW_COST",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXIT_CORRELATION",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXIT_MAX_HOLDING",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXIT_MEAN_REVERSION",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXIT_STOP_LOSS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "GUARDIAN_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "KEEPER_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_BATCH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_DEADLINE_WINDOW",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MIN_ENTRY_NOTIONAL",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "REGISTRAR_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "check",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "action",
        "type": "uint8",
        "internalType": "enum StrategyEngine.Action"
      },
      {
        "name": "detail",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "z",
        "type": "int256",
        "internalType": "int256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "clock",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IMarketClock"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "defaultParams",
    "inputs": [],
    "outputs": [
      {
        "name": "entryZ",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "exitZ",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "stopZ",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxHolding",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "cooldown",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "confirmDelay",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "armWindow",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minCorrelation",
        "type": "int256",
        "internalType": "int256"
      },
      {
        "name": "exitCorrelation",
        "type": "int256",
        "internalType": "int256"
      },
      {
        "name": "maxBorrowApr",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "execute",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "executeBatch",
    "inputs": [
      {
        "name": "list",
        "type": "address[]",
        "internalType": "address[]"
      },
      {
        "name": "deadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "executed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getRoleAdmin",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "grantRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "hasRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "params",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "paused",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "registerVault",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "renounceRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "callerConfirmation",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "revokeRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setDefaultParams",
    "inputs": [
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setParams",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "spreadOracle",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract ISpreadOracle"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "supportsInterface",
    "inputs": [
      {
        "name": "interfaceId",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "unpause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "vaultCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaultInfo",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "registered",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "armedDirection",
        "type": "uint8",
        "internalType": "enum IPairVault.State"
      },
      {
        "name": "armedAt",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "lastActionAt",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaults",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "Armed",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "direction",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum IPairVault.State"
      },
      {
        "name": "z",
        "type": "int256",
        "indexed": false,
        "internalType": "int256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DefaultParamsSet",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Executed",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "action",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum StrategyEngine.Action"
      },
      {
        "name": "detail",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      },
      {
        "name": "z",
        "type": "int256",
        "indexed": false,
        "internalType": "int256"
      },
      {
        "name": "keeper",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ParamsSet",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "params",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct StrategyEngine.Params",
        "components": [
          {
            "name": "entryZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "exitZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopZ",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxHolding",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "cooldown",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "confirmDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armWindow",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "exitCorrelation",
            "type": "int256",
            "internalType": "int256"
          },
          {
            "name": "maxBorrowApr",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Paused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleAdminChanged",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "previousAdminRole",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "newAdminRole",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleGranted",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleRevoked",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Unpaused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VaultRegistered",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AccessControlBadConfirmation",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AccessControlUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "neededRole",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "AlreadyRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadDeadline",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadParams",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BatchTooLarge",
    "inputs": []
  },
  {
    "type": "error",
    "name": "EnforcedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ExpectedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NothingToDo",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  }
] as const;
