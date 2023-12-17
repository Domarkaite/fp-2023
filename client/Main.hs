{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main (main) where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Free (Free (..))
import Data.Functor((<&>))
 
import Control.Lens ((^.), view)
import Data.Time ( UTCTime, getCurrentTime )
import Data.List qualified as L
import Lib1 qualified
import Lib2 qualified
import Lib3 qualified
import Lib4 qualified
import DataFrame
import InMemoryTables
import Control.Lens
import Data.Aeson (ToJSON, FromJSON)
import Data.Yaml
import GHC.Generics
import Control.Lens
import Data.Aeson (ToJSON, FromJSON)
import Data.Yaml
import qualified Data.ByteString.Lazy as BSL
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import System.Console.Repline
  ( CompleterStyle (Word),
    ExitDecision (Exit),
    HaskelineT,
    WordCompleter,
    evalRepl,
  )

import System.Console.Terminal.Size (Window, size, width)
import Lib2 (tableNameParser)
import System.Directory (doesFileExist, getDirectoryContents)
import System.FilePath (pathSeparator)



type Repl a = HaskelineT IO a
final :: Repl ExitDecision
final = do
  liftIO $ putStrLn "Goodbye!"
  return Exit


ini :: Repl ()
ini = liftIO $ putStrLn "Welcome to client-server database! Press [TAB] for auto completion."


completer :: (Monad m) => WordCompleter m
completer n = do
  let names = [
              "select", "*", "from", "show", "table",
              "tables", "insert", "into", "values",
              "set", "update", "delete"
              ]
  return $ Prelude.filter (L.isPrefixOf n) names

data ServerResponse = ServerResponse
    { responseRight :: Maybe DataFrame
    , responseLeft :: Maybe ErrorMessage
    } deriving (Show, Eq, Generic)

type ErrorMessage = String

instance ToJSON ServerResponse
instance FromJSON ServerResponse


-- Evaluation : handle each line user inputs
cmd :: String -> Repl ()
cmd input = do
  s <- terminalWidth <$> liftIO size
  result <- liftIO $ sendQuery input
  case result of
    Left err -> liftIO $ putStrLn $ "Error: " ++ err
    Right df -> do
        liftIO $ putStrLn $ Lib1.renderDataFrameAsTable s df
  where
    terminalWidth :: Integral n => Maybe (Window n) -> n
    terminalWidth = maybe 80 width
            

sendQuery :: String -> IO (Either ErrorMessage DataFrame)
sendQuery query = do
    let yamlData = query
    initialRequest <- parseRequest "http://localhost:1395/query"
    let request = initialRequest
            { method = "POST"
            , requestBody = RequestBodyLBS $ BSL.toStrict $ encode yamlData
            , requestHeaders = [("Content-Type", "application/yaml")]
            }

    manager <- newManager tlsManagerSettings
    response <- httpLbs request manager

    case decode (BSL.toStrict $ responseBody response) :: Maybe DataFrame of
      Just df -> return $ Right df
      Nothing -> return $ Left "Failed to decode DataFrame"


main :: IO ()
main =
  evalRepl (const $ pure ">>> ") cmd [] Nothing Nothing (Word completer) ini final