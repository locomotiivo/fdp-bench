use {
    crate::bench_tps_client::{BenchTpsClient, BenchTpsError, Result},
    solana_rpc_client::rpc_client::RpcClient,
    solana_sdk::{
        account::Account, commitment_config::CommitmentConfig, epoch_info::EpochInfo, hash::Hash,
        message::Message, pubkey::Pubkey, signature::Signature, transaction::Transaction, slot_history::Slot,
    },
};

impl BenchTpsClient for RpcClient {
    fn send_transaction(&self, transaction: Transaction) -> Result<Signature> {
        RpcClient::send_transaction(self, &transaction).map_err(|err| err.into())
    }
    fn send_batch(&self, transactions: Vec<Transaction>) -> Result<()> {
        for transaction in transactions {
            BenchTpsClient::send_transaction(self, transaction)?;
        }
        Ok(())
    }
    fn get_latest_blockhash(&self) -> Result<Hash> {
        RpcClient::get_latest_blockhash(self).map_err(|err| err.into())
    }

    fn get_latest_blockhash_with_commitment(
        &self,
        commitment_config: CommitmentConfig,
    ) -> Result<(Hash, u64)> {
        RpcClient::get_latest_blockhash_with_commitment(self, commitment_config)
            .map_err(|err| err.into())
    }

    fn get_transaction_count(&self) -> Result<u64> {
        RpcClient::get_transaction_count(self).map_err(|err| err.into())
    }

    fn get_transaction_count_with_commitment(
        &self,
        commitment_config: CommitmentConfig,
    ) -> Result<u64> {
        RpcClient::get_transaction_count_with_commitment(self, commitment_config)
            .map_err(|err| err.into())
    }

    fn get_epoch_info(&self) -> Result<EpochInfo> {
        RpcClient::get_epoch_info(self).map_err(|err| err.into())
    }

    fn get_balance(&self, pubkey: &Pubkey) -> Result<u64> {
        RpcClient::get_balance(self, pubkey).map_err(|err| err.into())
    }

    fn get_balance_with_commitment(
        &self,
        pubkey: &Pubkey,
        commitment_config: CommitmentConfig,
    ) -> Result<u64> {
        RpcClient::get_balance_with_commitment(self, pubkey, commitment_config)
            .map(|res| res.value)
            .map_err(|err| err.into())
    }

    fn get_fee_for_message(&self, message: &Message) -> Result<u64> {
        RpcClient::get_fee_for_message(self, message).map_err(|err| err.into())
    }

    fn get_minimum_balance_for_rent_exemption(&self, data_len: usize) -> Result<u64> {
        RpcClient::get_minimum_balance_for_rent_exemption(self, data_len).map_err(|err| err.into())
    }

    fn addr(&self) -> String {
        self.url()
    }

    fn request_airdrop_with_blockhash(
        &self,
        pubkey: &Pubkey,
        lamports: u64,
        recent_blockhash: &Hash,
    ) -> Result<Signature> {
        RpcClient::request_airdrop_with_blockhash(self, pubkey, lamports, recent_blockhash)
            .map_err(|err| err.into())
    }

    fn get_account(&self, pubkey: &Pubkey) -> Result<Account> {
        RpcClient::get_account(self, pubkey).map_err(|err| err.into())
    }

    fn get_account_with_commitment(
        &self,
        pubkey: &Pubkey,
        commitment_config: CommitmentConfig,
    ) -> Result<Account> {
        RpcClient::get_account_with_commitment(self, pubkey, commitment_config)
            .map(|res| res.value)
            .map_err(|err| err.into())
            .and_then(|account| {
                account.ok_or_else(|| {
                    BenchTpsError::Custom(format!("AccountNotFound: pubkey={pubkey}"))
                })
            })
    }

    fn get_multiple_accounts(&self, pubkeys: &[Pubkey]) -> Result<Vec<Option<Account>>> {
        RpcClient::get_multiple_accounts(self, pubkeys).map_err(|err| err.into())
    }

    fn get_slot_with_commitment(&self, commitment_config: CommitmentConfig) -> Result<Slot> {
        RpcClient::get_slot_with_commitment(self, commitment_config).map_err(|err| err.into())
    }

    fn get_signature_statuses(
        &self,
        signatures: &[Signature],
    ) -> Result<Vec<Option<(Slot, bool)>>> {
        let response = RpcClient::get_signature_statuses(self, signatures)
            .map_err(|err| BenchTpsError::from(err))?;
        Ok(response.value.into_iter()
            .map(|opt| opt.map(|s| (s.slot, s.err.is_some())))
            .collect())
    }

    fn get_slot_entries(&self, slot: Slot) -> Result<Vec<String>> {
        // Get block data and count transactions using simple get_block (returns default with Full details)
        match RpcClient::get_block(self, slot) {
            Ok(block) => {
                // EncodedConfirmedBlock has transactions field
                let tx_count = block.transactions.len();
                println!("DEBUG RpcClient Slot {}: {} transactions", slot, tx_count);
                Ok(vec!["tx".to_string(); tx_count])
            }
            Err(e) => {
                println!("DEBUG RpcClient Failed to get block for slot {}: {:?}", slot, e);
                Ok(vec![])
            }
        }
    }
}
