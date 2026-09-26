/* Small ethers v6 helpers used by the static frontend. */
(function(){
  let provider;
  let signer;
  let activeTransaction=false;

  function ensureTransactionUi(){
    let root=document.getElementById('aqua-transaction-ui');
    if(root) return root;
    root=document.createElement('div');
    root.id='aqua-transaction-ui';
    root.className='aqua-tx-overlay';
    root.hidden=true;
    root.innerHTML=`
      <div class="aqua-tx-dialog" role="status" aria-live="polite">
        <div class="aqua-tx-spinner" data-tx-spinner></div>
        <div class="aqua-tx-title" data-tx-title>Transaction</div>
        <div class="aqua-tx-message" data-tx-message></div>
        <a class="aqua-tx-hash" data-tx-hash target="_blank" rel="noopener"></a>
        <button class="aqua-tx-close" data-tx-close type="button" hidden>Close</button>
      </div>`;
    document.body.appendChild(root);
    root.querySelector('[data-tx-close]').addEventListener('click',()=>{
      if(!activeTransaction) root.hidden=true;
    });
    return root;
  }

  function updateTransactionUi({title,message,state='pending',hash,chainKey}){
    const root=ensureTransactionUi();
    root.hidden=false;
    root.dataset.state=state;
    root.querySelector('[data-tx-title]').textContent=title;
    root.querySelector('[data-tx-message]').textContent=message;
    root.querySelector('[data-tx-spinner]').hidden=state!=='pending';
    const close=root.querySelector('[data-tx-close]');
    close.hidden=state==='pending';
    const hashLink=root.querySelector('[data-tx-hash]');
    hashLink.textContent=hash?'View transaction':' '; 
    hashLink.href=hash?`${AquaConfig.AquaChains[chainKey]?.explorer||''}/tx/${hash}`:'#';
  }

  async function executeTransaction({label='Transaction',chainKey=AquaConfig.AQUA_CHAIN,action}){
    if(activeTransaction) throw new Error('Another transaction is already in progress');
    activeTransaction=true;
    updateTransactionUi({title:label,message:'Confirm the transaction in your wallet',chainKey});
    try{
      const submitted=await action();
      if(submitted?.hash){
        updateTransactionUi({title:label,message:'Transaction submitted. Waiting for confirmation…',state:'pending',hash:submitted.hash,chainKey});
      }
      const receipt=submitted?.wait ? await submitted.wait() : submitted;
      updateTransactionUi({title:'Transaction complete',message:`${label} completed successfully`,state:'success',hash:receipt?.hash||submitted?.hash,chainKey});
      return receipt;
    }catch(error){
      const rejected=error?.code===4001 || error?.code==='ACTION_REJECTED';
      updateTransactionUi({title:rejected?'Transaction cancelled':'Transaction failed',message:rejected?'You rejected the request':(error?.shortMessage||error?.reason||error?.message||'Unknown blockchain error'),state:'error',chainKey});
      throw error;
    }finally{
      activeTransaction=false;
    }
  }

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

  async function writeContract({contractKey,address,abi,functionName,args=[],overrides={},chainKey=AquaConfig.AQUA_CHAIN,wait=true,label=functionName}){
    const send=async()=>{
      const contract=getContract({contractKey,address,abi,chainKey,write:true});
      return contract[functionName](...args,overrides);
    };
    if(wait) return executeTransaction({
      label,
      chainKey,
      action:send,
    });
    return send();
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

  window.AquaTx={executeTransaction,isBusy:()=>activeTransaction};
  window.AquaWeb3={setWalletProvider,getProvider,getAddress,getContract,readContract,simulateContract,writeContract,formatTokenAmount,parseTokenAmount,tokenAmount,formatToken};
})();
