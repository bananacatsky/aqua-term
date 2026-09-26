const AquaApi={
  baseUrl:window.AQUA_API_BASE||'http://127.0.0.1:5002/api',
  appAddress:'0x0000000000000000000000000000000000000abc',
  requestId:0,
  market:null,
  portfolio:null,
  currentAddress:null,

  async request(path,params={}){
    const url=new URL(`${this.baseUrl}/${path.replace(/^\//,'')}`);
    Object.entries(params).forEach(([key,value])=>{if(value!==undefined&&value!==null)url.searchParams.set(key,value)});
    const response=await fetch(url);
    const payload=await response.json();
    if(!response.ok) throw new Error(payload.error||`API request failed (${response.status})`);
    return payload;
  },

  async loadForAddress(address){
    if(!address) throw new Error('Wallet address is required');
    const requestId=++this.requestId;
    const params={app:this.appAddress,chain:'ethereum',address};
    const market=await this.request('market',params);
    const [portfolio,orders,...orderbooks]=await Promise.all([
      this.request('portfolio',params),
      this.request('orders',{app:params.app,chain:params.chain,maker:address}),
      ...market.maturities.map(item=>this.request('orderbook',{app:params.app,chain:params.chain,maturity:item.timestamp})),
    ]);
    if(requestId!==this.requestId) return null;
    this.market=market;
    this.portfolio=portfolio;
    this.currentAddress=address;
    this.renderMarket(market);
    const createOrder=document.getElementById('create-order');
    if(createOrder) createOrder.classList.remove('wallet-disconnected');
    this.renderPortfolio(portfolio);
    orderbooks.forEach((item,index)=>this.renderOrderbook(item,index,true));
    this.renderOpenOrders(orders);
    const status=document.getElementById('api-status');
    if(status){status.textContent='API: connected';status.className='api-status online'}
    return {market,portfolio,orders,orderbooks};
  },

  async loadPublicData(){
    const requestId=++this.requestId;
    const params={app:this.appAddress,chain:'ethereum'};
    const market=await this.request('market',params);
    const orderbooks=await Promise.all(market.maturities.map(item=>this.request('orderbook',{...params,maturity:item.timestamp})));
    if(requestId!==this.requestId) return null;
    this.renderMarket(market);
    orderbooks.forEach((item,index)=>this.renderOrderbook(item,index));
    const status=document.getElementById('api-status');
    if(status){status.textContent='API: public data';status.className='api-status online'}
    return {market,orderbooks};
  },

  clearDashboard(){
    this.requestId+=1;
    this.market=null;
    this.portfolio=null;
    this.currentAddress=null;
    const portfolio=document.getElementById('portfolio');
    if(portfolio) portfolio.classList.add('wallet-disconnected');
    const createOrder=document.getElementById('create-order');
    if(createOrder) createOrder.classList.add('wallet-disconnected');
    ['wallet-balance-value','debt-value','collateral-value','health-factor-value','current-ltv-value','borrow-limit-value','liquidation-limit-value','health-factor-risk-value'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.textContent='';
    });
    ['debts-list','lending-list','collateral-list','wallet-list','open-orders-list'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.replaceChildren();
    });
    const maturitySelect=document.getElementById('maturity-select');
    if(maturitySelect) maturitySelect.replaceChildren();
    const collateralSelect=document.querySelector('#borrow-fields select');
    if(collateralSelect) collateralSelect.replaceChildren();
    const depositSelect=document.getElementById('deposit-token-select');
    if(depositSelect) depositSelect.replaceChildren();
    ['deposit-token-balance','deposited-token-balance'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.textContent='';
    });
    document.querySelectorAll('.maturity-tab').forEach(tab=>{tab.textContent='';tab.hidden=false;});
    document.querySelectorAll('#portfolio > .grid, #portfolio > .card').forEach(section=>{section.hidden=true;});
    const portfolioHead=document.querySelector('#portfolio > .page-head');
    if(portfolioHead) portfolioHead.hidden=true;
    const message=document.getElementById('portfolio-connect-message');
    if(message) message.style.display='flex';
  },

  renderMarket(data){
    const maturitySelect=document.getElementById('maturity-select');
    if(maturitySelect) maturitySelect.innerHTML=data.maturities.map(item=>`<option value="${item.timestamp}">${item.label}</option>`).join('');
    const collateralSelect=document.querySelector('#borrow-fields select');
    if(collateralSelect) collateralSelect.innerHTML=data.collaterals.map(item=>`<option value="${item.id}">${item.symbol}</option>`).join('');
    const depositSelect=document.getElementById('deposit-token-select');
    if(depositSelect){
      depositSelect.innerHTML=data.collaterals.map(item=>`<option value="${item.id}">${item.symbol}</option>`).join('');
      this.updateDepositBalance();
    }
    document.querySelectorAll('.maturity-tab').forEach((tab,index)=>{
      const maturity=data.maturities[index];
      if(maturity) { tab.textContent=maturity.label; tab.hidden=false; }
      else tab.hidden=true;
    });
  },

  renderPortfolio(data){
    const portfolio=document.getElementById('portfolio');
    if(portfolio) portfolio.classList.remove('wallet-disconnected');
    document.querySelectorAll('#portfolio > .grid, #portfolio > .card').forEach(section=>{section.hidden=false;});
    const portfolioHead=document.querySelector('#portfolio > .page-head');
    if(portfolioHead) portfolioHead.hidden=false;
    const message=document.getElementById('portfolio-connect-message');
    if(message) message.style.display='none';
    const set=(id,value)=>{const el=document.getElementById(id);if(el)el.textContent=value};
    const usdt=v=>`${(Number(v)/1e6).toLocaleString('en-US',{maximumFractionDigits:2})} USDT`;
    const usd=v=>`$${(Number(v)/1e6).toLocaleString('en-US',{maximumFractionDigits:2})}`;
    const usdCents=v=>`$${(Number(v)/100).toLocaleString('en-US',{maximumFractionDigits:2})}`;
    const wallet=data.wallet.reduce((map,item)=>(map[item.token.symbol.toLowerCase()]=item.amount,map),{});
    set('wallet-balance-value',data.wallet_value_usd_cents==null?'':usdCents(data.wallet_value_usd_cents));
    set('debt-value',usdt(data.risk.total_debt));
    set('collateral-value',usd(data.risk.collateral_value));
    set('health-factor-value',data.risk.health_factor||'');
    set('current-ltv-value',`${(data.risk.current_ltv_bps/100).toFixed(1)}%`);
    set('borrow-limit-value',`${(data.risk.max_borrow_ltv_bps/100).toFixed(0)}%`);
    set('liquidation-limit-value',`${(data.risk.liquidation_ltv_bps/100).toFixed(0)}%`);
    set('health-factor-risk-value',data.risk.health_factor||'');
    const statusClass=data.risk.health_status==='healthy'?'green':(data.risk.health_status==='unhealthy'?'gray':'orange');
    ['health-status-pill','health-status-section'].forEach(id=>{const el=document.getElementById(id);if(el){el.className=`pill ${statusClass}`;el.textContent=data.risk.health_status||'';}});
    set('health-description',data.risk.health_message||'');
    const riskbar=document.getElementById('riskbar-value');
    if(riskbar) riskbar.style.width=`${Math.max(0,Math.min(100,Number(data.risk.risk_percent||0)))}%`;
    set('wallet-usdt-amount',usdt(wallet.usdt||0));
    set('wallet-weth-amount',`${(Number(wallet.weth||0)/1e18).toFixed(2)} WETH`);
    set('wallet-wbtc-amount',`${(Number(wallet.wbtc||0)/1e8).toFixed(3)} WBTC`);
    const collateral=data.collateral.reduce((map,item)=>(map[item.token.symbol.toLowerCase()]=item.amount,map),{});
    set('collateral-weth-amount',`${(Number(collateral.weth||0)/1e18).toFixed(2)} WETH`);
    set('collateral-wbtc-amount',`${(Number(collateral.wbtc||0)/1e8).toFixed(3)} WBTC`);
    this.updateDepositBalance();

    const debts=document.getElementById('debts-list');
    if(debts) debts.innerHTML=data.debts.map(item=>`<div class="position-row"><div><div class="num">Debt · ${item.label}</div><div class="muted">Fixed maturity</div></div><div><div class="num">${usdt(item.face_debt)}</div><div class="muted">Outstanding</div></div><div><div class="num">${usdt(item.written_down)}</div><div class="muted">Written down</div></div><button class="btn btn-primary">Repay</button></div>`).join('');
    const lending=document.getElementById('lending-list');
    if(lending) lending.innerHTML=data.lending.map(item=>`<div class="position-row"><div><div class="num">${item.label}</div><div class="muted">Fixed maturity</div></div><div><div class="num">${usdt(item.assets)}</div><div class="muted">Lent now</div></div><div><div class="num">${usdt(item.redeemable_assets)}</div><div class="muted">Redeemable now</div></div><button class="btn btn-primary">Redeem</button></div>`).join('');
    const collateralList=document.getElementById('collateral-list');
    if(collateralList) collateralList.innerHTML=data.collateral.map(item=>`<div class="token-row"><div class="token"><div class="coin">${item.token.symbol}</div><div><div class="num">${item.token.symbol==='WETH'?(Number(item.amount)/1e18).toFixed(3):(Number(item.amount)/1e8).toFixed(3)} ${item.token.symbol}</div><div class="muted">Deposited</div></div></div><div><div class="num">${(Number(data.risk.collateral_value)/1e6).toLocaleString('en-US')} USDT</div><div class="muted">Portfolio value</div></div></div>`).join('');
    const walletList=document.getElementById('wallet-list');
    if(walletList) walletList.innerHTML=data.wallet.map(item=>`<div class="token-row"><div class="token"><div class="coin">${item.token.symbol}</div><div><div class="num">${item.token.symbol==='USDT'?(Number(item.amount)/1e6).toFixed(2):(item.token.symbol==='WETH'?(Number(item.amount)/1e18).toFixed(3):(Number(item.amount)/1e8).toFixed(3))} ${item.token.symbol}</div><div class="muted">Wallet</div></div></div><div class="num">—</div></div>`).join('');
  },

  selectedCollateral(){
    const select=document.getElementById('deposit-token-select');
    const id=Number(select?.value);
    return this.market?.collaterals?.find(item=>item.id===id)||null;
  },

  updateDepositBalance(){
    const token=this.selectedCollateral();
    const walletBalanceEl=document.getElementById('deposit-token-balance');
    const depositedBalanceEl=document.getElementById('deposited-token-balance');
    const walletItem=this.portfolio?.wallet?.find(entry=>entry.token.symbol===token?.symbol);
    const depositedItem=this.portfolio?.collateral?.find(entry=>entry.token.symbol===token?.symbol);
    if(walletBalanceEl) walletBalanceEl.textContent=token&&walletItem?`${ethers.formatUnits(walletItem.amount,token.decimals)} ${token.symbol}`:'';
    if(depositedBalanceEl) depositedBalanceEl.textContent=token&&depositedItem?`${ethers.formatUnits(depositedItem.amount,token.decimals)} ${token.symbol}`:'';
  },

  renderOpenOrders(data){
    const openOrders=document.getElementById('open-orders-list');
    if(!openOrders) return;
    const rows=[...(data.borrow?.items||[]).map(item=>`<div class="order-row"><div><div class="num">Borrow · ${item.maturity}</div><div class="muted">Open order</div></div><div class="num">${(Number(item.remaining_face||item.face_amount)/1e6).toLocaleString('en-US')} USDT</div><span class="pill orange">Open</span></div>`),...(data.supply?.items||[]).map(item=>`<div class="order-row"><div><div class="num">Lend · ${item.maturity}</div><div class="muted">Open order</div></div><div class="num">${(Number(item.remaining_debt_token||item.debt_token_in)/1e6).toLocaleString('en-US')} USDT</div><span class="pill orange">Open</span></div>` )];
    openOrders.innerHTML=rows.join('');
  },

  renderOrderbook(data,index=0,showMatch=false){
    const panel=document.querySelectorAll('[data-panel]')[index];
    if(!panel)return;
    const amount=v=>`${(Number(v)/1e6).toLocaleString('en-US',{maximumFractionDigits:0})} USDT`;
    const row=(item,type)=>{
      const now=type==='lender'?item.debt_token_in:item.min_debt_token_out;
      const later=type==='lender'?item.min_term_out:item.face_amount;
      const rate=((Number(later)/Number(now)-1)*100).toFixed(1);
      return `<div class="ladder-row ${type==='lender'?'lender':'borrower'}"><div><span class="side-badge"><span class="side-dot"></span>${type==='lender'?'Lend':'Borrow'}</span><span class="muted">${type==='lender'?'Lend now':'Get now'}</span><br><b>${amount(now)}</b></div><div class="flow-arrow">${type==='lender'?'→':'←'}</div><div><span class="muted">${type==='lender'?'Receive later':'Repay later'}</span><br><b>${amount(later)}</b></div><div class="rate">${rate}%</div></div>`;
    };
    const match=showMatch?'<div class="match-zone"><div class="match-title">Match available</div><div class="reward">Available to execute</div><button class="btn btn-primary" style="margin-top:9px;width:100%">Match!</button></div>':'';
    panel.innerHTML=data.buy.items.map(item=>row(item,'lender')).join('')+match+data.sell.items.map(item=>row(item,'borrower')).join('');
  },
};
window.AquaApi=AquaApi;
