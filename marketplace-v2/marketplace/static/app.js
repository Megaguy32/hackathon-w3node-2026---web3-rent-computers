(() => {
  const $ = (id) => document.getElementById(id);
  let config = null;
  let abi = null;

  async function loadConfig() {
    const [cfg, contractAbi] = await Promise.all([
      fetch('/api/config').then(r => r.json()),
      fetch('/abi.json').then(r => r.json())
    ]);
    config = cfg;
    abi = contractAbi;
  }

  async function getSigner() {
    if (!window.ethereum) throw new Error('MetaMask or a compatible injected wallet is required.');
    if (!config?.configured) throw new Error('The marketplace contract is not configured on the backend.');
    await window.ethereum.request({ method: 'eth_requestAccounts' });
    const currentChain = BigInt(await window.ethereum.request({ method: 'eth_chainId' }));
    if (currentChain !== BigInt(config.chainId)) {
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: '0xaa36a7' }]
        });
      } catch (e) {
        throw new Error('Switch MetaMask to Ethereum Sepolia (chain ID 11155111), then try again.');
      }
    }
    const provider = new ethers.BrowserProvider(window.ethereum);
    return { provider, signer: await provider.getSigner() };
  }

  async function getContract() {
    const { signer } = await getSigner();
    return new ethers.Contract(config.contractAddress, abi, signer);
  }

  $('connect-wallet').addEventListener('click', async () => {
    try {
      const { signer } = await getSigner();
      const address = await signer.getAddress();
      $('wallet-address').textContent = `${address.slice(0, 6)}…${address.slice(-4)}`;
    } catch (e) { $('wallet-address').textContent = e.message; }
  });

  $('listing-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const message = $('listing-message');
    message.textContent = 'Waiting for wallet confirmation…';
    try {
      const machine = $('machine-name').value.trim();
      const price = $('price-eth').value;
      const duration = BigInt($('duration-seconds').value);
      if (!machine) throw new Error('Select a provider machine first.');
      const contract = await getContract();
      const tx = await contract.registerListing(machine, ethers.parseEther(price), duration);
      message.textContent = `Transaction submitted: ${tx.hash}`;
      await tx.wait();
      message.textContent = 'Listing registered. Waiting for the backend to index the event…';
      htmx.trigger($('listing-list'), 'load');
    } catch (e) { message.textContent = e.shortMessage || e.message; }
  });

  document.body.addEventListener('click', async (event) => {
    const button = event.target.closest('.rent-button');
    if (!button) return;
    const message = $('rental-message');
    button.disabled = true;
    message.textContent = 'Waiting for wallet confirmation…';
    try {
      const contract = await getContract();
      const tx = await contract.rent(BigInt(button.dataset.listingId), { value: BigInt(button.dataset.priceWei) });
      message.textContent = `Rental transaction submitted: ${tx.hash}`;
      await tx.wait();
      message.textContent = 'Payment confirmed. Waiting for the rental event to be indexed…';
      htmx.trigger($('rental-list'), 'load');
    } catch (e) { message.textContent = e.shortMessage || e.message; }
    finally { button.disabled = false; }
  });

  loadConfig().catch(e => console.error('Marketplace configuration:', e));
  if (window.ethereum) {
    window.ethereum.on?.('accountsChanged', (accounts) => {
      $('wallet-address').textContent = accounts.length ? `${accounts[0].slice(0, 6)}…${accounts[0].slice(-4)}` : 'Wallet not connected';
    });
    window.ethereum.on?.('chainChanged', () => window.location.reload());
  }
})();
