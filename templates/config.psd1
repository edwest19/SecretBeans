# ---------------------------------------------------------------------------
#  SecretBeans configuration template
#
#  Written by Claude (Anthropic) with Edwin West, August 2026.
#  Not an Anthropic product. See PROVENANCE.md.
# ---------------------------------------------------------------------------

# SecretBeans configuration - copy this into your ledger folder and edit.
#
# One entry per account you download. The only thing SecretBeans needs to know is
# which downloaded file belongs to which account; everything about the CSV's shape
# lives in the matching .rules file, which is why a new institution needs a rules
# file rather than a change to the tool.

@{
    # Where period folders are created. Keep this OUT of the SecretBeans repo -
    # it holds your financial data and belongs in a private repo of its own.
    LedgerRoot    = 'C:\Users\you\source\repos\MyLedger'

    Currency      = '$'
    OpeningEquity = 'equity:opening balances'

    # Anything the rules cannot identify is sent here rather than to a catch-all
    # that silently absorbs it. Check this after every import.
    ReviewAccount = 'expenses:review'

    Accounts = @(
        @{
            Name           = 'primary'          # short, stable; names the CSV, the rules file and the journal block
            Match          = 'Chase5678*'       # matches the download, whose name changes every month
            Account        = 'assets:bank:chase:checking:primary'
            Type           = 'bank'             # picks the starter rules template
            OpeningBalance = 14884.32           # from a statement; without it a 24-month window starts at zero
        }
        @{
            Name           = 'freedom'
            Match          = 'Chase1234*'
            Account        = 'liabilities:creditcard:chase:freedom'
            Type           = 'card'
            OpeningBalance = -1250.00           # a card balance you owe is negative
        }

        # Other shapes work the same way - write a rules file, add a line here:
        #
        # @{ Name='broker'; Match='*Fidelity*'; Account='assets:investment:fidelity'; Type='investment' }
        # @{ Name='mortgage'; Match='*Mortgage*'; Account='liabilities:mortgage'; Type='loan' }
        # @{ Name='paypal'; Match='*PayPal*'; Account='assets:paypal'; Type='payapp' }
        # @{ Name='hsa'; Match='*Optum*'; Account='assets:hsa:optum'; Type='hsa' }
    )
}
