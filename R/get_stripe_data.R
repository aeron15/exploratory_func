#' Get data from stripe API
#' @param endpoint Name of target data to access under https://api.stripe.com/v1/
#' e.g. "users", "charges"
#' @param date_type Type of date_since argument. Can be "exact", "days", "weeks", "months" or "years".
#' "exact" uses exact date like "2016-01-01".
#' "days", "weeks", "months" or "years" uses a number and get data from that time ago.
#' @param date_since From when data should be returned.
#' @export
get_stripe_data <- function(endpoint = "balance/history",
                            date_type = "exact",
                            date_since = NULL,
                            query_string = "", ...
                            ){
  # these were once arguments
  limit = 100
  paginate = NULL

  token_info <- getTokenInfo("stripe")
  access_token <- if(!is.null(token_info) && !is.null(token_info$access_token)){
    token_info$access_token
  } else {
    stop("No access token is set.")
  }

  token <- HttrOAuthToken2.0$new(
    authorize = "https://connect.stripe.com/oauth/authorize",
    access = "https://connect.stripe.com/oauth/token",
    revoke = "https://connect.stripe.com/oauth/deauthorize",
    appname = "stripe",
    credentials = list(
      access_token = access_token
    )
  )
  url <- if(endpoint == "files"){
    # only files need a different url https://stripe.com/docs/api/curl#list_file_uploads
    paste0("https://uploads.stripe.com/v1/", endpoint)
  } else {
    paste0("https://api.stripe.com/v1/", endpoint)
  }
  if (str_length(query_string) > 0) { # append custom query string
    url <- paste0(url, "?", query_string)
  }

  if(!is.null(date_since)){
    if(date_type != "exact"){
      if(!date_type %in% c("days", "weeks", "months", "years")){
        stop("date_type must be \"days\", \"weeks\", \"months\", \"years\" or \"exact\"")
      }
      date_since <- lubridate::today() - lubridate::period(as.numeric(date_since), units = date_type)
    } else {
      # format validation if it can be regarded as Date format
      date_since <- tryCatch({
        as.Date(date_since)
      }, error = function(e){
        stop("date_since can't be recognized as date. It should be \"2016-08-26\", for example")
      })
    }
  }

  get_data <- function(query, body){
    res <- httr::GET(url,
                     query = query,
                     body = body,
                     token
    )
    if(httr::status_code(res) != 200){
      stop(paste0("Error Response: ", httr::content(res, as = "text")))
    }
    from_json <- res %>% httr::content(as = "text") %>% jsonlite::fromJSON(flatten = TRUE)
    if(length(from_json$data) == 0){
      stop("No data found.")
    }
    from_json$data
  }

  query <- list(limit = limit)
  if(!is.null(date_since)){
    min_unixtime <- as.numeric(as.POSIXct(date_since))
    query[["created[gte]"]] <- min_unixtime
  }

  ret <- list()
  last_id <- NULL
  i <- 0
  while(TRUE){
    if(!is.null(last_id)){
      # search data after the last id in fetched data
      query$starting_after <- last_id
    }
    data <- tryCatch({
      get_data(query, body)
    }, error = function(e){
      if(stringr::str_detect(e$message, "^Error Response:")){
        stop(e)
      }
      NULL
    })
    if(is.null(data)){
      break()
    } else {
      last_id <- tail(data$id, 1)
      # this is to avoid duplicated rownames error when binding
      rownames(data) <- c()
      row.names(data) <- c()
      ret <- append(ret, list(data))
    }
    i <- i + 1
    if(!is.null(paginate) && i >= paginate){
      break()
    }
    Sys.sleep(0.2)
  }
  ret <- do.call(dplyr::bind_rows, ret)

  # convert unixtime integer column to datetime
  for(column in colnames(ret)){
    if(
      (
        grepl("date$", column) ||
        grepl("period_end$", column) ||
        grepl("period_start$", column) ||
        grepl("at$", column) ||
        grepl("created$", column) ||
        grepl("start$", column) ||
        grepl("end$", column) ||
        grepl("payment_attempt$", column) ||
        grepl("_on$", column) # there is available_on column for balance/history
      )
      &&
      is.integer(ret[[column]])
    ){
      ret[[column]] <- unixtime_to_datetime(ret[[column]])
    }
  }

  ret
}
