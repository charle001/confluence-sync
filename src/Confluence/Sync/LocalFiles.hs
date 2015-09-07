{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE QuasiQuotes #-}

module Confluence.Sync.LocalFiles (
  FoundFile(..)
, LocalAttachment(..)
, isPage
, findFilesInDirectory
, friendlyName
, prettyName
, getPageContents
, getAttachments
, localAttachmentRemoteName
) where

import           Control.Monad (forM, filterM)

import           Crypto.Hash
import           CMark

import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Char8 as BSC

import           Data.Char
import           Data.String.Utils
import           Data.List (intercalate, isPrefixOf, find, elem, reverse, foldl')
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import qualified Network.URL as URL

import           Text.XML.HXT.Core
import           Text.HandsomeSoup
import           Text.Heredoc

import           System.Directory (doesDirectoryExist, doesFileExist, getDirectoryContents,)
import           System.FilePath

import           Confluence.Sync.XmlRpc.Types

-------------------------------------------------------------------------------
-- General Local File Handling.
-------------------------------------------------------------------------------

data FoundFile = FoundFile {
  -- File name (including extension).
  name        :: String
  -- Full path to the file.
, fullPath    :: FilePath
  -- The path to this directory relative to the root of the site.
, directories :: [ String ]
  -- Root of the sync directory.
, rootPath    :: FilePath
} deriving Show

isPage :: FoundFile -> Bool
isPage f = (isMarkdownPage f) || (isHtmlPage f)

isMarkdownPage :: FoundFile -> Bool
isMarkdownPage file = Set.member (map toLower (takeExtension (name file))) markdownExtensions
  where markdownExtensions = Set.fromList [ ".md", ".markdown" ]

isHtmlPage :: FoundFile -> Bool
isHtmlPage file = Set.member (map toLower (takeExtension (name file))) htmlExtensions
  where htmlExtensions = Set.fromList [ ".html", ".htm" ]

friendlyName :: FoundFile -> String
friendlyName file = prettyName $ dropExtension (name file)

-- Takes a filename and makes into something which is nice for page titles.
-- This involves replacing special characters and capitalising each word.
prettyName :: String -> String
prettyName string = 
  (unwords . map capitaliseWord . words) $ (foldr replaceCharacter string [
      ("-", " ")
    , ("_", " ")
  ])
  where replaceCharacter :: (String, String) -> String -> String
        replaceCharacter (needle, replaced) str = replace needle replaced str
        capitaliseWord :: String -> String
        capitaliseWord [] = []
        capitaliseWord (c : cs) = toUpper c : map toLower cs

-------------------------------------------------------------------------------
-- Local Attachment Handling.
-------------------------------------------------------------------------------

data LocalAttachment = LocalAttachment {
  -- Filename of the attachment.
  localAttachmentName  :: String
  -- How it is referenced in the document (e.g. what path is used to refer to it)
, localReference       :: String
  -- Actual path to file contents on disk.
, localAttachmentPath  :: FilePath
  -- Path relative to the sync root.
, attachmentRelativePath  :: FilePath
}

-- Generates the filename of the attachment in Confluence
localAttachmentRemoteName :: LocalAttachment -> IO String
localAttachmentRemoteName local = do
  hash <- attachmentHash local
  let relative = attachmentRelativePath local
  let extension = takeExtension relative
  let baseName = dropExtension relative
  let safeName = replace "/" "_" (replace "_" "__" baseName)
  return $ safeName ++ "_" ++ hash ++ extension

attachmentHash :: LocalAttachment -> IO String
attachmentHash LocalAttachment { localAttachmentPath } = do
  contents <- LBS.readFile localAttachmentPath
  return . BSC.unpack $ digestToHexByteString $ md5 contents
  where md5 :: LBS.ByteString -> Digest MD5
        md5 = hashlazy

getAttachments :: FoundFile -> IO [ LocalAttachment ]
getAttachments (file@FoundFile { fullPath, rootPath }) = do
  pageContents <- getPageAsRawHtml file
  references   <- findLocalAttachments pageContents
  let decodePath path = maybe path id (URL.decString False path)
  let all = (flip fmap) references $ (\path ->
              let pathToAttachment = normalizePath $ if (isPrefixOf "/" path) 
                                      then (rootPath </> (tail path))
                                      else ((takeDirectory fullPath) </> path)
              in LocalAttachment (takeFileName path) path (decodePath pathToAttachment) (decodePath (makeRelative rootPath pathToAttachment))
            )
  let validExtensions = Set.fromList [ ".pdf", ".jpeg", ".jpg", ".png", ".js", ".css" ]
      onlyValidExtensions LocalAttachment { localAttachmentName } = Set.member (map toLower (takeExtension (localAttachmentName))) validExtensions
      onlyAttachables = filter onlyValidExtensions all
  
  filterM (\la -> doesFileExist $ localAttachmentPath la) onlyAttachables

-------------------------------------------------------------------------------
-- Helper functions for rewriting site urls.
-------------------------------------------------------------------------------

getPageAsRawHtml :: FoundFile -> IO T.Text
getPageAsRawHtml (file@FoundFile { fullPath }) =
  if (isHtmlPage file) then (TIO.readFile fullPath)
    else if (isMarkdownPage file) then (\html -> wrapMarkdownHtml html) <$> (commonmarkToHtml [optSafe, optSmart]) <$> (TIO.readFile fullPath)
    else return ""

getPageContents :: FoundFile -> [ (LocalAttachment, Attachment) ] -> [ (FoundFile, PageSummary) ] -> IO String
getPageContents (file@FoundFile { fullPath }) attachmentMapping pageMapping = 
  if (isHtmlPage file) then htmlContent
    else if (isMarkdownPage file) then markdownContent
    else return ""
  where htmlContent     = wrapHtml <$> ((getPageAsRawHtml file) >>= processAttachments >>= processLinks)
        markdownContent = wrapHtml <$> ((getPageAsRawHtml file) >>= processAttachments >>= processLinks)
        processLinks = rewriteLinks pageMapping file
        processAttachments = rewriteAttachmentReferences referenceToUrl
          where referenceToUrl = Map.fromList $ fmap (\(l, r) -> ((localReference l), (attachmentUrl r))) attachmentMapping
        wrapHtml :: String -> String
        wrapHtml contents = concat [ prefix, contents, suffix ]
          where prefix = "<ac:macro ac:name='html'><ac:plain-text-body><![CDATA["
                suffix = "]]></ac:plain-text-body></ac:macro>"
          
-------------------------------------------------------------------------------
-- Helper functions for rewriting site urls.
-------------------------------------------------------------------------------

type SiteReference = String
type AttachmentUrl = String
type LinkedPageUrl = String

lowerCase str = map toLower str
notDataUri uri = not (isPrefixOf "data:" (lowerCase uri))
notExternalUri uri = not ((isPrefixOf "http:" (lowerCase uri)) || (isPrefixOf "https:" (lowerCase uri)))
isSiteUri uri = (notDataUri uri) && (notExternalUri uri)
modifyAttribute name f = changeAttrValue f `when` hasName name

-------------------------------------------------------------------------------
-- Link rewriting
-------------------------------------------------------------------------------

rewriteLinks :: [ (FoundFile, PageSummary) ] -> FoundFile -> String -> IO String
rewriteLinks pageMapping file html =
  let doc = readString [withParseHTML yes, withWarnings no] $ html
      isSiteLink = isElem >>> hasName "a" >>> hasAttr "href" >>> getAttrValue "href" >>> isA isSiteUri
      findPage = fromLinkToPage pageMapping file
      updateReference reference = maybe reference id (findPage reference)
      replaceLinks = processAttrl (modifyAttribute "href" updateReference) `when` isSiteLink
      parseAndReplace = runX $ doc >>> 
        processTopDown replaceLinks
        >>> writeDocumentToString [ withOutputEncoding isoLatin1 ]
  in concat <$> parseAndReplace

fromLinkToPage :: [ (FoundFile, PageSummary) ] -> FoundFile -> SiteReference -> Maybe LinkedPageUrl
fromLinkToPage pageMapping currentFile reference =
  let relativeToRootReference = if (isPrefixOf "/" reference) 
        then dropTrailingPathSeparator $ (tail reference)
        else normalizePath $ dropTrailingPathSeparator $ (joinPath $ (directories currentFile) ++ [ reference ])
      searchPaths = if (hasExtension relativeToRootReference) 
        then [ relativeToRootReference
             , ((dropExtension relativeToRootReference) <.> "md")
             , (dropExtension relativeToRootReference)
             , ((dropExtension relativeToRootReference) <.> "markdown") ]
        else [ (relativeToRootReference </> "index")
             , (relativeToRootReference <.> ".html")
             , (relativeToRootReference <.> ".htm")
             , (relativeToRootReference <.> ".md")
             , (relativeToRootReference <.> ".markdown")
             , (relativeToRootReference </> "index.html")
             , (relativeToRootReference </> "index.md")
             , (relativeToRootReference </> "index.htm")
             , (relativeToRootReference </> "index.markdown") ]
      normalizedSearchPaths = fmap lowerCase searchPaths
      normalizedRelativeToRoot file = lowerCase $ makeRelative (rootPath file) (fullPath file)
      maybeFileAndSummary = find (\(ff, ps) -> (normalizedRelativeToRoot ff) `elem` normalizedSearchPaths) pageMapping
  in (\(ff, ps) -> pageSummaryUrl ps) <$> maybeFileAndSummary

normalizePath :: FilePath -> FilePath
normalizePath path = 
  foldl' (</>) "" (filter (/= "./") (reverse (recurseParent components)))
  where components = reverse (splitPath path)
        safeTail []     = []
        safeTail (x:xs) = xs
        recurseParent []     = []
        recurseParent (x:xs) = if (x == "../")
                          then (recurseParent (safeTail xs))
                          else x : (recurseParent xs) 
-------------------------------------------------------------------------------
-- Asset parsing/replacing (with attachments)
-------------------------------------------------------------------------------

-- | Finds all files referenced in the page that need to be attached to it.
--   For example, this includes images and PDFs.
--
-- >>> findLocalAttachments $ T.pack "<body><a href='/foo.pdf'>My Link</a><img src='my_fancy_pic.png' /></body>"
-- ["/foo.pdf","my_fancy_pic.png"]
--
-- >>> findLocalAttachments $ T.pack "<body><img src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg==' alt='Red dot' /></body>"
-- []
--
-- >>> findLocalAttachments $ T.pack "<body><a href='HTTP://www.google.com/foo.pdf'>My Link</a><img src='https://imgur.com/my_fancy_pic.png' /></body>"
-- []
--
findLocalAttachments :: T.Text -> IO [FilePath]
findLocalAttachments html = do
  let doc = readString [withParseHTML yes, withWarnings no] $ T.unpack html
  allReferences <- runX $ doc >>> (css "a" ! "href") <+> (css "img" ! "src") <+> (css "link" ! "href")
  return $ filter isSiteUri allReferences

-- Rewrites references to images to point to the attachment urls.
rewriteAttachmentReferences :: (Map SiteReference AttachmentUrl) -> T.Text -> IO String
rewriteAttachmentReferences referenceToUrl html =
  let doc = readString [withParseHTML yes, withWarnings no] $ T.unpack html
      isSiteLink = isElem >>> hasName "a" >>> hasAttr "href" >>> getAttrValue "href" >>> isA isSiteUri
      isSiteImage = isElem >>> hasName "img" >>> hasAttr "src" >>> getAttrValue "src" >>> isA isSiteUri
      isSiteLinkedResource = isElem >>> hasName "link" >>> hasAttr "href" >>> getAttrValue "href" >>> isA isSiteUri
      isSiteScript = isElem >>> hasName "script" >>> hasAttr "src" >>> getAttrValue "src" >>> isA isSiteUri
      updateReference existing = Map.findWithDefault existing existing referenceToUrl
      replaceLinks = processAttrl (modifyAttribute "href" updateReference) `when` isSiteLink
      replaceLinkedResources = processAttrl (modifyAttribute "href" updateReference) `when` isSiteLinkedResource
      replaceImages = processAttrl (modifyAttribute "src" updateReference) `when` isSiteImage
      replaceScripts = processAttrl (modifyAttribute "src" updateReference) `when` isSiteScript
      parseAndReplace = runX $ doc >>> 
        (processTopDown replaceLinks) 
        >>> (processTopDown replaceImages)
        >>> (processTopDown replaceLinkedResources)
        >>> (processTopDown replaceScripts)
        >>> writeDocumentToString [ withOutputEncoding isoLatin1 ]
  in concat <$> parseAndReplace

-------------------------------------------------------------------------------
-- Find files to sync.
-------------------------------------------------------------------------------

-- Recurses through a directory and finds files to sync.
findFilesInDirectory :: FilePath -> IO [FoundFile]
findFilesInDirectory root = 
  recurse [] root
  where recurse directories current = do
          -- Get contents of the directory
          names <- getDirectoryContents current
          -- Only select actual files/folders
          let properNames = filter (`notElem` [".", ".."]) names
          -- Iterate through the list of files.
          found <- forM properNames $ \name -> do
            -- Construct the full path to the file.
            let fullPath = current </> name
            -- Check whether it is a directory.
            isDirectory <- doesDirectoryExist fullPath
            if isDirectory
              -- Recurse on any directory we find (add the directory to the hirearchy.)
              then recurse (name : directories) fullPath
              else return [ (FoundFile name fullPath (reverse directories) root) ]
          return (concat found)

-------------------------------------------------------------------------------
-- Markdown HTML Wrapping.
-------------------------------------------------------------------------------

-- | Wraps the Markdown generated output in a class to isolate the effects of the CSS.
--
wrapMarkdownHtml :: T.Text -> T.Text
wrapMarkdownHtml content = githubCss `mappend` "<div class='markdown-body'>" `mappend` content `mappend` "</div>"

githubCss = [here|
<style>
@font-face {
  font-family: octicons-anchor;
  src: url(data:font/woff;charset=utf-8;base64,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) format('woff');
}

.markdown-body {
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
  color: #333;
  overflow: hidden;
  font-family: "Helvetica Neue", Helvetica, "Segoe UI", Arial, freesans, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  word-wrap: break-word;
}

.markdown-body a {
  background-color: transparent;
}

.markdown-body a:active,
.markdown-body a:hover {
  outline: 0;
}

.markdown-body strong {
  font-weight: bold;
}

.markdown-body h1 {
  font-size: 2em;
  margin: 0.67em 0;
}

.markdown-body img {
  border: 0;
}

.markdown-body hr {
  box-sizing: content-box;
  height: 0;
}

.markdown-body pre {
  overflow: auto;
}

.markdown-body code,
.markdown-body kbd,
.markdown-body pre {
  font-family: monospace, monospace;
  font-size: 1em;
}

.markdown-body input {
  color: inherit;
  font: inherit;
  margin: 0;
}

.markdown-body html input[disabled] {
  cursor: default;
}

.markdown-body input {
  line-height: normal;
}

.markdown-body input[type="checkbox"] {
  box-sizing: border-box;
  padding: 0;
}

.markdown-body table {
  border-collapse: collapse;
  border-spacing: 0;
}

.markdown-body td,
.markdown-body th {
  padding: 0;
}

.markdown-body * {
  box-sizing: border-box;
}

.markdown-body input {
  font: 13px/1.4 Helvetica, arial, nimbussansl, liberationsans, freesans, clean, sans-serif, "Segoe UI Emoji", "Segoe UI Symbol";
}

.markdown-body a {
  color: #4078c0;
  text-decoration: none;
}

.markdown-body a:hover,
.markdown-body a:active {
  text-decoration: underline;
}

.markdown-body hr {
  height: 0;
  margin: 15px 0;
  overflow: hidden;
  background: transparent;
  border: 0;
  border-bottom: 1px solid #ddd;
}

.markdown-body hr:before {
  display: table;
  content: "";
}

.markdown-body hr:after {
  display: table;
  clear: both;
  content: "";
}

.markdown-body h1,
.markdown-body h2,
.markdown-body h3,
.markdown-body h4,
.markdown-body h5,
.markdown-body h6 {
  margin-top: 15px;
  margin-bottom: 15px;
  line-height: 1.1;
}

.markdown-body h1 {
  font-size: 30px;
}

.markdown-body h2 {
  font-size: 21px;
}

.markdown-body h3 {
  font-size: 16px;
}

.markdown-body h4 {
  font-size: 14px;
}

.markdown-body h5 {
  font-size: 12px;
}

.markdown-body h6 {
  font-size: 11px;
}

.markdown-body blockquote {
  margin: 0;
}

.markdown-body ul,
.markdown-body ol {
  padding: 0;
  margin-top: 0;
  margin-bottom: 0;
}

.markdown-body ol ol,
.markdown-body ul ol {
  list-style-type: lower-roman;
}

.markdown-body ul ul ol,
.markdown-body ul ol ol,
.markdown-body ol ul ol,
.markdown-body ol ol ol {
  list-style-type: lower-alpha;
}

.markdown-body dd {
  margin-left: 0;
}

.markdown-body code {
  font-family: Consolas, "Liberation Mono", Menlo, Courier, monospace;
  font-size: 12px;
}

.markdown-body pre {
  margin-top: 0;
  margin-bottom: 0;
  font: 12px Consolas, "Liberation Mono", Menlo, Courier, monospace;
}

.markdown-body .select::-ms-expand {
  opacity: 0;
}

.markdown-body .octicon {
  font: normal normal normal 16px/1 octicons-anchor;
  display: inline-block;
  text-decoration: none;
  text-rendering: auto;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  -webkit-user-select: none;
  -moz-user-select: none;
  -ms-user-select: none;
  user-select: none;
}

.markdown-body .octicon-link:before {
  content: '\f05c';
}

.markdown-body>*:first-child {
  margin-top: 0 !important;
}

.markdown-body>*:last-child {
  margin-bottom: 0 !important;
}

.markdown-body a:not([href]) {
  color: inherit;
  text-decoration: none;
}

.markdown-body .anchor {
  position: absolute;
  top: 0;
  left: 0;
  display: block;
  padding-right: 6px;
  padding-left: 30px;
  margin-left: -30px;
}

.markdown-body .anchor:focus {
  outline: none;
}

.markdown-body h1,
.markdown-body h2,
.markdown-body h3,
.markdown-body h4,
.markdown-body h5,
.markdown-body h6 {
  position: relative;
  margin-top: 1em;
  margin-bottom: 16px;
  font-weight: bold;
  line-height: 1.4;
}

.markdown-body h1 .octicon-link,
.markdown-body h2 .octicon-link,
.markdown-body h3 .octicon-link,
.markdown-body h4 .octicon-link,
.markdown-body h5 .octicon-link,
.markdown-body h6 .octicon-link {
  display: none;
  color: #000;
  vertical-align: middle;
}

.markdown-body h1:hover .anchor,
.markdown-body h2:hover .anchor,
.markdown-body h3:hover .anchor,
.markdown-body h4:hover .anchor,
.markdown-body h5:hover .anchor,
.markdown-body h6:hover .anchor {
  padding-left: 8px;
  margin-left: -30px;
  text-decoration: none;
}

.markdown-body h1:hover .anchor .octicon-link,
.markdown-body h2:hover .anchor .octicon-link,
.markdown-body h3:hover .anchor .octicon-link,
.markdown-body h4:hover .anchor .octicon-link,
.markdown-body h5:hover .anchor .octicon-link,
.markdown-body h6:hover .anchor .octicon-link {
  display: inline-block;
}

.markdown-body h1 {
  padding-bottom: 0.3em;
  font-size: 2.25em;
  line-height: 1.2;
  border-bottom: 1px solid #eee;
}

.markdown-body h1 .anchor {
  line-height: 1;
}

.markdown-body h2 {
  padding-bottom: 0.3em;
  font-size: 1.75em;
  line-height: 1.225;
  border-bottom: 1px solid #eee;
}

.markdown-body h2 .anchor {
  line-height: 1;
}

.markdown-body h3 {
  font-size: 1.5em;
  line-height: 1.43;
}

.markdown-body h3 .anchor {
  line-height: 1.2;
}

.markdown-body h4 {
  font-size: 1.25em;
}

.markdown-body h4 .anchor {
  line-height: 1.2;
}

.markdown-body h5 {
  font-size: 1em;
}

.markdown-body h5 .anchor {
  line-height: 1.1;
}

.markdown-body h6 {
  font-size: 1em;
  color: #777;
}

.markdown-body h6 .anchor {
  line-height: 1.1;
}

.markdown-body p,
.markdown-body blockquote,
.markdown-body ul,
.markdown-body ol,
.markdown-body dl,
.markdown-body table,
.markdown-body pre {
  margin-top: 0;
  margin-bottom: 16px;
}

.markdown-body hr {
  height: 4px;
  padding: 0;
  margin: 16px 0;
  background-color: #e7e7e7;
  border: 0 none;
}

.markdown-body ul,
.markdown-body ol {
  padding-left: 2em;
}

.markdown-body ul ul,
.markdown-body ul ol,
.markdown-body ol ol,
.markdown-body ol ul {
  margin-top: 0;
  margin-bottom: 0;
}

.markdown-body li>p {
  margin-top: 16px;
}

.markdown-body dl {
  padding: 0;
}

.markdown-body dl dt {
  padding: 0;
  margin-top: 16px;
  font-size: 1em;
  font-style: italic;
  font-weight: bold;
}

.markdown-body dl dd {
  padding: 0 16px;
  margin-bottom: 16px;
}

.markdown-body blockquote {
  padding: 0 15px;
  color: #777;
  border-left: 4px solid #ddd;
}

.markdown-body blockquote>:first-child {
  margin-top: 0;
}

.markdown-body blockquote>:last-child {
  margin-bottom: 0;
}

.markdown-body table {
  display: block;
  width: 100%;
  overflow: auto;
  word-break: normal;
  word-break: keep-all;
}

.markdown-body table th {
  font-weight: bold;
}

.markdown-body table th,
.markdown-body table td {
  padding: 6px 13px;
  border: 1px solid #ddd;
}

.markdown-body table tr {
  background-color: #fff;
  border-top: 1px solid #ccc;
}

.markdown-body table tr:nth-child(2n) {
  background-color: #f8f8f8;
}

.markdown-body img {
  max-width: 100%;
  box-sizing: border-box;
}

.markdown-body code {
  padding: 0;
  padding-top: 0.2em;
  padding-bottom: 0.2em;
  margin: 0;
  font-size: 85%;
  background-color: rgba(0,0,0,0.04);
  border-radius: 3px;
}

.markdown-body code:before,
.markdown-body code:after {
  letter-spacing: -0.2em;
  content: "\00a0";
}

.markdown-body pre>code {
  padding: 0;
  margin: 0;
  font-size: 100%;
  word-break: normal;
  white-space: pre;
  background: transparent;
  border: 0;
}

.markdown-body .highlight {
  margin-bottom: 16px;
}

.markdown-body .highlight pre,
.markdown-body pre {
  padding: 16px;
  overflow: auto;
  font-size: 85%;
  line-height: 1.45;
  background-color: #f7f7f7;
  border-radius: 3px;
}

.markdown-body .highlight pre {
  margin-bottom: 0;
  word-break: normal;
}

.markdown-body pre {
  word-wrap: normal;
}

.markdown-body pre code {
  display: inline;
  max-width: initial;
  padding: 0;
  margin: 0;
  overflow: initial;
  line-height: inherit;
  word-wrap: normal;
  background-color: transparent;
  border: 0;
}

.markdown-body pre code:before,
.markdown-body pre code:after {
  content: normal;
}

.markdown-body kbd {
  display: inline-block;
  padding: 3px 5px;
  font-size: 11px;
  line-height: 10px;
  color: #555;
  vertical-align: middle;
  background-color: #fcfcfc;
  border: solid 1px #ccc;
  border-bottom-color: #bbb;
  border-radius: 3px;
  box-shadow: inset 0 -1px 0 #bbb;
}

.markdown-body .pl-c {
  color: #969896;
}

.markdown-body .pl-c1,
.markdown-body .pl-s .pl-v {
  color: #0086b3;
}

.markdown-body .pl-e,
.markdown-body .pl-en {
  color: #795da3;
}

.markdown-body .pl-s .pl-s1,
.markdown-body .pl-smi {
  color: #333;
}

.markdown-body .pl-ent {
  color: #63a35c;
}

.markdown-body .pl-k {
  color: #a71d5d;
}

.markdown-body .pl-pds,
.markdown-body .pl-s,
.markdown-body .pl-s .pl-pse .pl-s1,
.markdown-body .pl-sr,
.markdown-body .pl-sr .pl-cce,
.markdown-body .pl-sr .pl-sra,
.markdown-body .pl-sr .pl-sre {
  color: #183691;
}

.markdown-body .pl-v {
  color: #ed6a43;
}

.markdown-body .pl-id {
  color: #b52a1d;
}

.markdown-body .pl-ii {
  background-color: #b52a1d;
  color: #f8f8f8;
}

.markdown-body .pl-sr .pl-cce {
  color: #63a35c;
  font-weight: bold;
}

.markdown-body .pl-ml {
  color: #693a17;
}

.markdown-body .pl-mh,
.markdown-body .pl-mh .pl-en,
.markdown-body .pl-ms {
  color: #1d3e81;
  font-weight: bold;
}

.markdown-body .pl-mq {
  color: #008080;
}

.markdown-body .pl-mi {
  color: #333;
  font-style: italic;
}

.markdown-body .pl-mb {
  color: #333;
  font-weight: bold;
}

.markdown-body .pl-md {
  background-color: #ffecec;
  color: #bd2c00;
}

.markdown-body .pl-mi1 {
  background-color: #eaffea;
  color: #55a532;
}

.markdown-body .pl-mdr {
  color: #795da3;
  font-weight: bold;
}

.markdown-body .pl-mo {
  color: #1d3e81;
}

.markdown-body kbd {
  display: inline-block;
  padding: 3px 5px;
  font: 11px Consolas, "Liberation Mono", Menlo, Courier, monospace;
  line-height: 10px;
  color: #555;
  vertical-align: middle;
  background-color: #fcfcfc;
  border: solid 1px #ccc;
  border-bottom-color: #bbb;
  border-radius: 3px;
  box-shadow: inset 0 -1px 0 #bbb;
}

.markdown-body .task-list-item {
  list-style-type: none;
}

.markdown-body .task-list-item+.task-list-item {
  margin-top: 3px;
}

.markdown-body .task-list-item input {
  margin: 0 0.35em 0.25em -1.6em;
  vertical-align: middle;
}

.markdown-body :checked+.radio-label {
  z-index: 1;
  position: relative;
  border-color: #4078c0;
}
</style>
|]