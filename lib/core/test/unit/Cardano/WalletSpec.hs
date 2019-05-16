{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.WalletSpec
    ( spec
    ) where

import Prelude

import Cardano.Crypto.Wallet
    ( unXPrv )
import Cardano.Wallet
    ( ErrCreateUnsignedTx (..)
    , ErrSignTx (..)
    , ErrSubmitTx (..)
    , ErrUpdatePassphrase (..)
    , ErrWithRootKey (..)
    , ErrWithRootKey (..)
    , WalletLayer (..)
    , newWalletLayer
    , unsafeRunExceptT
    )
import Cardano.Wallet.DB
    ( DBLayer, ErrNoSuchWallet (..), PrimaryKey (..) )
import Cardano.Wallet.DB.MVar
    ( newDBLayer )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (..)
    , ErrWrongPassphrase (..)
    , Key
    , Passphrase (..)
    , XPrv
    , generateKeyFromSeed
    )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( GenChange (..), IsOurs (..), IsOwned (..) )
import Cardano.Wallet.Primitive.Types
    ( Address (..)
    , Hash (..)
    , TxId (..)
    , WalletId (..)
    , WalletMetadata (..)
    , WalletName (..)
    )
import Control.Concurrent
    ( threadDelay )
import Control.DeepSeq
    ( NFData (..) )
import Control.Monad
    ( forM_, replicateM, void )
import Control.Monad.IO.Class
    ( liftIO )
import Control.Monad.Trans.Except
    ( runExceptT )
import Crypto.Hash
    ( hash )
import Data.ByteString
    ( ByteString )
import Data.Coerce
    ( coerce )
import Data.Either
    ( isLeft, isRight )
import Data.Maybe
    ( isJust, isNothing )
import GHC.Generics
    ( Generic )
import Test.Hspec
    ( Spec, describe, it, shouldBe, shouldNotBe, shouldSatisfy )
import Test.QuickCheck
    ( Arbitrary (..), Property, elements, property, (==>) )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary, genericShrink )
import Test.QuickCheck.Monadic
    ( monadicIO )

import qualified Cardano.Wallet.DB as DB
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.List as L

spec :: Spec
spec = do
    describe "Pointless tests to cover 'Show' instances for errors" $ do
        let errNoSuchWallet =
                ErrNoSuchWallet (WalletId (hash @ByteString "arbitrary"))
        it (show $ ErrCreateUnsignedTxNoSuchWallet errNoSuchWallet) True
        it (show $ ErrSignTxNoSuchWallet errNoSuchWallet) True
        it (show $ ErrSubmitTxNoSuchWallet errNoSuchWallet) True
        it (show $ ErrUpdatePassphraseNoSuchWallet errNoSuchWallet) True
        it (show $ ErrWithRootKeyWrongPassphrase ErrWrongPassphrase) True

    describe "WalletLayer works as expected" $ do
        it "Wallet upon creation is written down in db"
            (property walletCreationProp)
        it "Wallet cannot be created more than once"
            (property walletDoubleCreationProp)
        it "Wallet after being created can be got using valid wallet Id"
            (property walletGetProp)
        it "Wallet with wrong wallet Id cannot be got"
            (property walletGetWrongIdProp)
        it "Two wallets with same mnemonic have a same public id"
            (property walletIdDeterministic)
        it "Two wallets with different mnemonic have a different public id"
            (property walletIdInjective)
        it "Wallet has name corresponding to its last update"
            (property walletUpdateName)
        it "Can't change name if wallet doesn't exist"
            (property walletUpdateNameNoSuchWallet)
        it "Can change passphrase of the last private key attached, if any"
            (property walletUpdatePassphrase)
        it "Can't change passphrase with a wrong old passphrase"
            (property walletUpdatePassphraseWrong)
        it "Can't change passphrase if wallet doesn't exist"
            (property walletUpdatePassphraseNoSuchWallet)
        it "Passphrase info is up-to-date after wallet passphrase update"
            (property walletUpdatePassphraseDate)

{-------------------------------------------------------------------------------
                                    Properties
-------------------------------------------------------------------------------}

walletCreationProp
    :: (WalletId, WalletName, DummyState)
    -> Property
walletCreationProp newWallet = monadicIO $ liftIO $ do
    (WalletLayerFixture db _wl walletIds) <- setupFixture newWallet
    resFromDb <- DB.readCheckpoint db (PrimaryKey $ L.head walletIds)
    resFromDb `shouldSatisfy` isJust

walletDoubleCreationProp
    :: (WalletId, WalletName, DummyState)
    -> Property
walletDoubleCreationProp newWallet@(wid, wname, wstate) = monadicIO $ liftIO $ do
    (WalletLayerFixture _db wl _walletIds) <- setupFixture newWallet
    secondTrial <- runExceptT $ createWallet wl wid wname wstate
    secondTrial `shouldSatisfy` isLeft

walletGetProp
    :: (WalletId, WalletName, DummyState)
    -> Property
walletGetProp newWallet = monadicIO $ liftIO $ do
    (WalletLayerFixture _db wl walletIds) <- liftIO $ setupFixture newWallet
    resFromGet <- runExceptT $ readWallet wl (L.head walletIds)
    resFromGet `shouldSatisfy` isRight

walletGetWrongIdProp
    :: ((WalletId, WalletName, DummyState), WalletId)
    -> Property
walletGetWrongIdProp (newWallet, corruptedWalletId) = monadicIO $ liftIO $ do
    (WalletLayerFixture _db wl _walletIds) <- liftIO $ setupFixture newWallet
    attempt <- runExceptT $ readWallet wl corruptedWalletId
    attempt `shouldSatisfy` isLeft

walletIdDeterministic
    :: (WalletId, WalletName, DummyState)
    -> Property
walletIdDeterministic newWallet = monadicIO $ liftIO $ do
    (WalletLayerFixture _ _ widsA) <- liftIO $ setupFixture newWallet
    (WalletLayerFixture _ _ widsB) <- liftIO $ setupFixture newWallet
    widsA `shouldBe` widsB

walletIdInjective
    :: ((WalletId, WalletName, DummyState), (WalletId, WalletName, DummyState))
    -> Property
walletIdInjective (walletA, walletB) = monadicIO $ liftIO $ do
    (WalletLayerFixture _ _ widsA) <- liftIO $ setupFixture walletA
    (WalletLayerFixture _ _ widsB) <- liftIO $ setupFixture walletB
    widsA `shouldNotBe` widsB

walletUpdateName
    :: (WalletId, WalletName, DummyState)
    -> [WalletName]
    -> Property
walletUpdateName wallet@(_, wName0, _) names = monadicIO $ liftIO $ do
    (WalletLayerFixture _ wl [wid]) <- liftIO $ setupFixture wallet
    unsafeRunExceptT $ forM_ names $ \wName ->
        updateWallet wl wid (\x -> x { name = wName })
    wName <- fmap (name . snd) <$> unsafeRunExceptT $ readWallet wl wid
    wName `shouldBe` last (wName0 : names)

walletUpdateNameNoSuchWallet
    :: (WalletId, WalletName, DummyState)
    -> WalletId
    -> WalletName
    -> Property
walletUpdateNameNoSuchWallet wallet@(wid', _, _) wid wName =
    wid /= wid' ==> monadicIO $ liftIO $ do
        (WalletLayerFixture _ wl _) <- liftIO $ setupFixture wallet
        attempt <- runExceptT $ updateWallet wl wid (\x -> x { name = wName })
        attempt `shouldBe` Left (ErrNoSuchWallet wid)

walletUpdatePassphrase
    :: (WalletId, WalletName, DummyState)
    -> Passphrase "encryption-new"
    -> Maybe (Key 'RootK XPrv, Passphrase "encryption")
    -> Property
walletUpdatePassphrase wallet new mxprv = monadicIO $ liftIO $ do
    (WalletLayerFixture _ wl [wid]) <- liftIO $ setupFixture wallet
    case mxprv of
        Nothing -> prop_withoutPrivateKey wl wid
        Just (xprv, pwd) -> prop_withPrivateKey wl wid (xprv, pwd)
  where
    prop_withoutPrivateKey wl wid = do
        attempt <- runExceptT $ updateWalletPassphrase wl wid (coerce new, new)
        let err = ErrUpdatePassphraseWithRootKey $ ErrWithRootKeyNoRootKey wid
        attempt `shouldBe` Left err

    prop_withPrivateKey wl wid (xprv, pwd) = do
        unsafeRunExceptT $ attachPrivateKey wl wid (xprv, pwd)
        attempt <- runExceptT $ updateWalletPassphrase wl wid (coerce pwd, new)
        attempt `shouldBe` Right ()

walletUpdatePassphraseWrong
    :: (WalletId, WalletName, DummyState)
    -> (Key 'RootK XPrv, Passphrase "encryption")
    -> (Passphrase "encryption-old", Passphrase "encryption-new")
    -> Property
walletUpdatePassphraseWrong wallet (xprv, pwd) (old, new) =
    pwd /= coerce old ==> monadicIO $ liftIO $ do
        (WalletLayerFixture _ wl [wid]) <- liftIO $ setupFixture wallet
        unsafeRunExceptT $ attachPrivateKey wl wid (xprv, pwd)
        attempt <- runExceptT $ updateWalletPassphrase wl wid (old, new)
        let err = ErrUpdatePassphraseWithRootKey
                $ ErrWithRootKeyWrongPassphrase
                ErrWrongPassphrase
        attempt `shouldBe` Left err

walletUpdatePassphraseNoSuchWallet
    :: (WalletId, WalletName, DummyState)
    -> WalletId
    -> (Passphrase "encryption-old", Passphrase "encryption-new")
    -> Property
walletUpdatePassphraseNoSuchWallet wallet@(wid', _, _) wid (old, new) =
    wid /= wid' ==> monadicIO $ liftIO $ do
        (WalletLayerFixture _ wl _) <- liftIO $ setupFixture wallet
        attempt <- runExceptT $ updateWalletPassphrase wl wid (old, new)
        let err = ErrUpdatePassphraseWithRootKey (ErrWithRootKeyNoRootKey wid)
        attempt `shouldBe` Left err

walletUpdatePassphraseDate
    :: (WalletId, WalletName, DummyState)
    -> (Key 'RootK XPrv, Passphrase "encryption")
    -> Property
walletUpdatePassphraseDate wallet (xprv, pwd) = monadicIO $ liftIO $ do
    (WalletLayerFixture _ wl [wid]) <- liftIO $ setupFixture wallet
    let infoShouldSatisfy predicate = do
            info <- (passphraseInfo . snd) <$> unsafeRunExceptT (readWallet wl wid)
            info `shouldSatisfy` predicate
            return info

    void $ infoShouldSatisfy isNothing
    unsafeRunExceptT $ attachPrivateKey wl wid (xprv, pwd)
    info <- infoShouldSatisfy isJust
    pause
    unsafeRunExceptT $ updateWalletPassphrase wl wid (coerce pwd, coerce pwd)
    void $ infoShouldSatisfy (\info' -> isJust info' && info' > info)
  where
    pause = threadDelay 500

{-------------------------------------------------------------------------------
                      Tests machinery, Arbitrary instances
-------------------------------------------------------------------------------}

data WalletLayerFixture = WalletLayerFixture
    { _fixtureDBLayer :: DBLayer IO DummyState DummyTarget
    , _fixtureWalletLayer :: WalletLayer DummyState DummyTarget
    , _fixtureWallet :: [WalletId]
    }

setupFixture
    :: (WalletId, WalletName, DummyState)
    -> IO WalletLayerFixture
setupFixture (wid, wname, wstate) = do
    db <- newDBLayer
    let nl = error "NetworkLayer"
    let tl = error "TransactionLayer"
    wl <- newWalletLayer @_ @DummyTarget db nl tl
    res <- runExceptT $ createWallet wl wid wname wstate
    let wal = case res of
            Left _ -> []
            Right walletId -> [walletId]
    pure $ WalletLayerFixture db wl wal

data DummyTarget

instance TxId DummyTarget where
    txId = Hash . B8.pack . show

data DummyState = DummyState
    deriving (Generic, Show, Eq)

instance NFData DummyState

instance Arbitrary DummyState where
    shrink = genericShrink
    arbitrary = genericArbitrary

instance IsOurs DummyState where
    isOurs _ s = (True, s)

instance IsOwned DummyState where
    isOwned _ _ _ = Nothing

instance GenChange DummyState where
    genChange s = (Address "dummy", s)

instance Arbitrary WalletId where
    shrink _ = []
    arbitrary = do
        bytes <- BS.pack <$> replicateM 16 arbitrary
        return $ WalletId (hash bytes)

instance Arbitrary WalletName where
    shrink _ = []
    arbitrary = elements
        [ WalletName "My Wallet"
        , WalletName mempty
        ]

instance Arbitrary (Passphrase purpose) where
    shrink _ = []
    arbitrary =
        Passphrase . BA.convert . BS.pack <$> replicateM 16 arbitrary

instance {-# OVERLAPS #-} Arbitrary (Key 'RootK XPrv, Passphrase "encryption") where
    shrink _ = []
    arbitrary = do
        seed <- Passphrase . BA.convert . BS.pack <$> replicateM 32 arbitrary
        pwd <- arbitrary
        let key = generateKeyFromSeed (seed, mempty) pwd
        return (key, pwd)

instance Show XPrv where
    show = show . unXPrv