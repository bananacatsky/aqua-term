/* Small ethers v6 helpers used by the static frontend. */
(function(){
  let provider;
  let signer;

  function getChainConfig(chainKey=AquaConfig.AQUA_CHAIN){
    const chain=AquaConfig.AquaChains[chainKey];
    if(!chain) throw new Error(`Unknown chain: ${chainKey}`);
    return chain;
  }

  function getAddress(contractKey,chainKey=AquaConfig.AQUA_CHAIN){
    const contracts=AquaConfig.AquaContracts[chainKey];
    const address=contracts?.[contractKey];
    if(!address || address===AquaConfig.ZERO_ADDRESS){
      throw new Error(`Contract address is not configured: ${chainKey}.${contractKey}`);
    }
    return address;
  }

  function setWalletProvider(nextProvider,nextSigner){
    provider=nextProvider;
    signer=nextSigner;
  }

  function getProvider(){
    if(!provider) throw new Error('Wallet is not connected');
    return provider;
  }

  function getContract({contractKey,address,abi,chainKey=AquaConfig.AQUA_CHAIN,write=false}){
    const contractAddress=address||getAddress(contractKey,chainKey);
    const runner=write ? signer : (provider||new ethers.JsonRpcProvider(getChainConfig(chainKey).rpcUrl));
    if(write && !signer) throw new Error('Wallet is not connected');
    return new ethers.Contract(contractAddress,abi,runner);
  }

  async function readContract({contractKey,address,abi,functionName,args=[],chainKey=AquaConfig.AQUA_CHAIN}){
    const contract=getContract({contractKey,address,abi,chainKey});
    return contract[functionName](...args);
  }

  async function simulateContract({contractKey,address,abi,functionName,args=[],overrides={},chainKey=AquaConfig.AQUA_CHAIN}){
    const contract=getContract({contractKey,address,abi,chainKey});
    const data=contract.interface.encodeFunctionData(functionName,args);
    const result=await getProvider().call({to:contract.target,data,...overrides});
    return contract.interface.decodeFunctionResult(functionName,result);
  }

  async function writeContract({contractKey,address,abi,functionName,args=[],overrides={},chainKey=AquaConfig.AQUA_CHAIN,wait=true}){
    const contract=getContract({contractKey,address,abi,chainKey,write:true});
    const tx=await contract[functionName](...args,overrides);
    return wait ? tx.wait() : tx;
  }

  function formatTokenAmount(value,decimals=18,options={}){
    if(value===null || value===undefined) return '—';
    return ethers.formatUnits(value,decimals,options);
  }

  function parseTokenAmount(value,decimals=18){
    return ethers.parseUnits(String(value).trim(),decimals);
  }

  function tokenAmount(value,tokenKey){
    const token=AquaConfig.AquaTokens[tokenKey];
    if(!token) throw new Error(`Unknown token: ${tokenKey}`);
    return parseTokenAmount(value,token.decimals);
  }

  function formatToken(value,tokenKey){
    const token=AquaConfig.AquaTokens[tokenKey];
    if(!token) throw new Error(`Unknown token: ${tokenKey}`);
    return `${formatTokenAmount(value,token.decimals)} ${token.symbol}`;
  }

  window.AquaWeb3={setWalletProvider,getProvider,getAddress,getContract,readContract,simulateContract,writeContract,formatTokenAmount,parseTokenAmount,tokenAmount,formatToken};
})();
