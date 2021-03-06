{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Confluence.Sync.XmlRpc.Api (
  login
, logout

, getPage
, getPageByName
, getDescendents

, storePage
, createPage

, getAttachments
, addAttachment
, removeAttachment

, addSpace
, removeSpace
) where

import           Data.ByteString
import           Data.Int
import           Data.Time.LocalTime

import           Control.Exception
import           Control.Monad.Except
import           Control.Monad.Reader

import           Network.XmlRpc.Client
import           Network.XmlRpc.Internals

import           Confluence.Sync.Internal.RateLimiter
import           Confluence.Sync.XmlRpc.Requests
import           Confluence.Sync.XmlRpc.Types

type Username           = String
type Password           = String
type PageId             = String
type PageName           = String
type SpaceKey           = String
type AttachmentFileName = String

login :: ConfluenceUrl -> Username -> Password -> IO Token
login url = remote url "confluence2.login"

logout :: ApiCall Bool
logout = invoke "confluence2.logout"

getPage :: PageId -> ApiCall Page
getPage = invoke "confluence2.getPage"

getPageByName :: SpaceKey -> PageName -> ApiCall Page
getPageByName = invoke "confluence2.getPage"

getDescendents :: PageId -> ApiCall [PageSummary]
getDescendents = invoke "confluence2.getDescendents"

getAttachments :: PageId -> ApiCall [Attachment]
getAttachments = invoke "confluence2.getAttachments"

createPage :: NewPage -> ApiCall Page
createPage = invoke "confluence2.storePage"

storePage :: Page -> ApiCall Page
storePage = invoke "confluence2.storePage"

movePage :: PageId -> PageId -> String -> ApiCall String
movePage = invoke "confluence2.movePage"

addAttachment :: PageId -> NewAttachment -> ByteString -> ApiCall Attachment
addAttachment = invoke "confluence2.addAttachment"

removeAttachment :: PageId -> AttachmentFileName -> ApiCall Bool
removeAttachment = invoke "confluence2.removeAttachment"

addSpace :: Space -> ApiCall Space
addSpace = invoke "confluence2.addSpace"

removeSpace :: SpaceKey -> ApiCall Bool
removeSpace = invoke "confluence2.removeSpace"
