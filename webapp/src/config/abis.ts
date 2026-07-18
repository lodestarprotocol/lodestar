// Minimal ABIs, typed as const so viem/wagmi infer return types.

export const FTSO_ABI = [
  {
    type: 'function',
    name: 'getFeedById',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'bytes21' }],
    outputs: [
      { name: 'value', type: 'uint256' },
      { name: 'decimals', type: 'int8' },
      { name: 'timestamp', type: 'uint64' },
    ],
  },
] as const

export const POOL_ABI = [
  { type: 'function', name: 'totalAssets', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'principalOut', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'convertToAssets', stateMutability: 'view', inputs: [{ name: 'shares', type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ name: 'assets', type: 'uint256' }, { name: 'receiver', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'redeem', stateMutability: 'nonpayable', inputs: [{ name: 'shares', type: 'uint256' }, { name: 'receiver', type: 'address' }, { name: 'owner', type: 'address' }], outputs: [{ type: 'uint256' }] },
] as const

export const BOOK_ABI = [
  { type: 'function', name: 'open', stateMutability: 'nonpayable', inputs: [{ name: 'collateral', type: 'address' }, { name: 'amount', type: 'uint256' }, { name: 'tier', type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'repay', stateMutability: 'nonpayable', inputs: [{ name: 'id', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'partialRepay', stateMutability: 'nonpayable', inputs: [{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'minPrincipal', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint128' }] },
  { type: 'function', name: 'activeLoanCount', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'nextLoanId', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  {
    type: 'function',
    name: 'loans',
    stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'borrower', type: 'address' },
      { name: 'collateral', type: 'address' },
      { name: 'collAmount', type: 'uint256' },
      { name: 'principal', type: 'uint128' },
      { name: 'fee', type: 'uint128' },
      { name: 'principalUsd18', type: 'uint128' },
      { name: 'openedAt', type: 'uint64' },
      { name: 'dueAt', type: 'uint64' },
      { name: 'active', type: 'bool' },
      { name: 'openRate', type: 'uint128' },
      { name: 'impairedLoss', type: 'uint128' },
    ],
  },
] as const

export const ERC20_ABI = [
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
] as const
