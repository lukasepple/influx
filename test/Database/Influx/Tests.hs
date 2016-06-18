{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE OverloadedStrings #-}

module Database.Influx.Tests
   ( htf_thisModulesTests
   ) where

import Database.Influx

import Test.Framework
import Network.HTTP.Client.Conduit
import qualified Data.Text as T

testConfig :: IO Config
testConfig =
    do manager <- newManager
       pure
           Config
           { configCreds = Just creds
           , configServer = "http://localhost:8086"
           , configManager = manager
           }
  where
    creds =
        Credentials
        { credsUser = "root"
        , credsPassword = "root"
        }

test_ping :: IO ()
test_ping =
    do config <- testConfig
       res <- ping config
       assertBool $
           maybe False ((>= 1) . T.length . unInfluxVersion) res

test_getQuery :: IO ()
test_getQuery =
    do config <- testConfig
       res <- getQueryRaw config (defaultOptParams { optDatabase = Just "_internal" }) (Query "SHOW TAG KEYS FROM \"database\"")
       return ()

test_createDropDB :: IO ()
test_createDropDB =
    do config <- testConfig
       _ <- postQueryRaw config defaultOptParams "CREATE DATABASE integration_test"
       _ <- postQueryRaw config defaultOptParams "DROP DATABASE integration_test"
       return ()
