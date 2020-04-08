{-# LANGUAGE DataKinds #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Data.UTxO.Transaction.Cardano.Byron
    (
    -- * Initialization
      mkInit
    , mainnetMagic
    , testnetMagic

    -- * Constructing Primitives
    , mkInput
    , mkOutput
    , mkSignKey

    -- * Converting From Bases
    , fromBase16
    , fromBase58
    ) where

import Cardano.Binary
    ( FromCBOR (..), ToCBOR (..) )
import Cardano.Chain.Common
    ( mkAttributes, mkLovelace )
import Cardano.Chain.UTxO
    ( TxIn (..), TxInWitness (..), TxOut (..), TxSigData (..), mkTxAux )
import Cardano.Crypto.Hashing
    ( AbstractHash (..), hash )
import Cardano.Crypto.ProtocolMagic
    ( ProtocolMagicId (..) )
import Cardano.Crypto.Signing
    ( SignTag (..), Signature, SigningKey (..), VerificationKey (..) )
import Cardano.Crypto.Wallet
    ( toXPub, xprv )
import Cardano.Crypto.Wallet.Encrypted
    ( encryptedCreateDirectWithTweak, unEncryptedKey )
import Codec.CBOR.Read
    ( deserialiseFromBytes )
import Crypto.Hash
    ( Blake2b_256, digestFromByteString )
import Data.ByteArray.Encoding
    ( Base (..), convertFromBase )
import Data.ByteString
    ( ByteString )
import Data.ByteString.Base58
    ( bitcoinAlphabet, decodeBase58 )
import Data.List.NonEmpty
    ( NonEmpty )
import Data.Text
    ( Text )
import Data.UTxO.Transaction
    ( ErrMkPayment (..), MkPayment (..) )
import Data.Word
    ( Word32 )
import GHC.Exts
    ( IsList (fromList) )
import Numeric.Natural
    ( Natural )

import qualified Cardano.Chain.UTxO as CC
import qualified Cardano.Crypto.Signing as CC
import qualified Codec.CBOR.Write as CBOR
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.List.NonEmpty as NE
import qualified Data.Text.Encoding as T

-- | Construct a payment 'Init' for /Byron/ from primitive types.
--
-- __examples__:
--
-- >>> mkInit 764824073 == mainnetMagic
-- True
--
-- >>> mkInit 1097911063 == testnetMagic
-- True
mkInit
    :: Word32
        -- ^ A protocol magic id
    -> Init Byron
mkInit =
    ProtocolMagicId

-- | Pre-defined 'Init' magic for /Byron/ MainNet.
mainnetMagic :: Init Byron
mainnetMagic = mkInit 764824073

-- | Pre-defined 'Init' magic for /Byron/ TestNet.
testnetMagic :: Init Byron
testnetMagic = mkInit 1097911063

-- | Construct a payment 'Input' for /Byron/ from primitive types.
--
-- __example__:
--
-- >>> mkInput 14 =<< fromBase16 "3b402651...aad1c0b7"
-- Just (Input ...)
mkInput
    :: Word32
        -- ^ Input index.
    -> ByteString
        -- ^ Input transaction id. See also: 'fromBase16'.
    -> Maybe (Input Byron)
mkInput ix bytes =
    case digestFromByteString @Blake2b_256 bytes of
        Just txId -> Just $ TxInUtxo (AbstractHash txId) ix
        Nothing -> Nothing

-- | Construct a payment 'Output' for /Byron/ from primitive types.
--
-- __example__:
--
-- >>> mkOutput 42 =<< fromBase58 "Ae2tdPwU...DnXy319f"
-- Just (Output ...)
mkOutput
    :: Natural
        -- ^ Output value, in Lovelace (1 Ada = 1e6 Lovelace).
    -> ByteString
        -- ^ Output Address. See also: 'fromBase58'.
    -> Maybe (Output Byron)
mkOutput n bytes =
    case (fromCBOR' bytes, mkLovelace (fromIntegral n)) of
        (Right addr, Right coin) -> Just $ TxOut addr coin
        _ -> Nothing
  where
    fromCBOR' = fmap snd . deserialiseFromBytes fromCBOR .  BL.fromStrict

-- | Construct a 'SignKey' for /Byron/ from primitive types.
--
-- __example__:
--
-- >>> mkSignKey =<< fromBase16 "3b402651...aad1c0b7"
-- Just (SignKey ...)
mkSignKey
    :: ByteString
        -- ^ A extended address private key and its chain code.
        -- The key __must be 96 bytes__ long, internally made of two concatenated parts:
        --
        -- @
        -- BYTES = PRV | CC
        -- PRV   = 64OCTET  # a 64 bytes Ed25519 extended private key
        -- CC    = 32OCTET  # a 32 bytes chain code
        -- @
        --
        -- See also: 'fromBase16'.
    -> Maybe (SignKey Byron)
mkSignKey bytes
    | BS.length bytes /= 96 = Nothing
    | otherwise = do
        let ekey = encryptedCreateDirectWithTweak bytes (mempty :: ByteString)
        case xprv (unEncryptedKey ekey) of
            Right prv -> Just (SigningKey prv)
            Left{} -> Nothing

--
-- ByteString Decoding
--

-- | Convert a base16 encoded 'Text' into a raw 'ByteString'
fromBase16 :: Text -> Maybe ByteString
fromBase16 = either (const Nothing) Just . convertFromBase Base16 . T.encodeUtf8

-- | Convert a base58 encoded 'Text' into a raw 'ByteString'
fromBase58 :: Text -> Maybe ByteString
fromBase58 = decodeBase58 bitcoinAlphabet . T.encodeUtf8

--
-- MkPayment instance
--

data Byron

instance MkPayment Byron where
    type Init Byron = ProtocolMagicId

    type Input   Byron = TxIn
    type Output  Byron = TxOut
    type SignKey Byron = SigningKey

    type CoinSel Byron =
        (ProtocolMagicId, [TxIn], [TxOut])

    type Tx Byron = Either
        ErrMkPayment
        (ProtocolMagicId, NonEmpty TxIn, NonEmpty TxOut, TxSigData, [TxInWitness])

    empty :: ProtocolMagicId -> CoinSel Byron
    empty pm = (pm, mempty, mempty)

    addInput :: TxIn -> CoinSel Byron -> CoinSel Byron
    addInput inp (pm, inps, outs) = (pm, inp : inps, outs)

    addOutput :: TxOut -> CoinSel Byron -> CoinSel Byron
    addOutput out (pm, inps, outs) = (pm, inps, out : outs)

    lock :: CoinSel Byron -> Tx Byron
    lock (_pm, [], _outs) = Left MissingInput
    lock (_pm, _inps, []) = Left MissingOutput
    lock (pm, inps, outs) =
        Right (pm, neInps, neOuts, sigData, mempty)
      where
        sigData = TxSigData $ hash $ CC.UnsafeTx neInps neOuts (mkAttributes ())
        neInps  = NE.fromList $ reverse inps
        neOuts  = NE.fromList $ reverse outs

    signWith :: SigningKey -> Tx Byron -> Tx Byron
    signWith _ (Left e) = Left e
    signWith (SigningKey prv) (Right (pm, inps, outs, sigData, wits)) =
        Right (pm, inps, outs, sigData, VKWitness vk sig : wits)
      where
        vk :: VerificationKey
        vk = VerificationKey (toXPub prv)

        sig :: Signature TxSigData
        sig = CC.sign pm SignTx (SigningKey prv) sigData

    serialize :: Tx Byron -> Either ErrMkPayment ByteString
    serialize (Left e) = Left e
    serialize (Right (_pm, inps, outs, _sigData, wits))
        | NE.length inps /= length wits = Left MissingSignature
        | otherwise = Right $ CBOR.toStrictByteString $ toCBOR $ mkTxAux
            (CC.UnsafeTx inps outs (mkAttributes ()))
            (fromList $ reverse wits)
