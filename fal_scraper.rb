# frozen_string_literal: true

require "async"
require "net/http"
require "json"
require "rubyXL"
require "rubyXL/convenience_methods/workbook"
require "open-uri"
require "nokogiri"

CLIENT_ID = ""
IDS = [55_644, 54_918, 52_991, 50_664, 54_492, 52_990, 53_040, 51_215, 52_741, 55_742, 51_794, 54_743, 53_879, 50_184,
       54_362, 54_714, 54_103, 51_297, 53_833, 55_153, 52_347, 52_934, 53_300, 53_262, 52_962, 49_766, 54_798, 53_237].freeze

def get_response(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req["X-MAL-CLIENT-ID"] = CLIENT_ID

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
  JSON.parse(res.body)
end

def scrape_threads(id)
  url = "https://myanimelist.net/forum/?animeid=#{id}}&topic=episode"
  uri = URI.parse(url)

  res = Net::HTTP.get_response(uri)
  Nokogiri::HTML(res.body)
end

def get_data(id)
  url = "https://api.myanimelist.net/v2/anime/#{id}?fields=title,mean,num_favorites,statistics"
  get_response(url)
end

def get_topic_content(topic_id)
  url = "https://api.myanimelist.net/v2/forum/topic/#{topic_id}?limit=100"
  topic_content = [] << response = get_response(url)

  (1..).each do |i|
    url = "https://api.myanimelist.net/v2/forum/topic/#{topic_id}?offset=#{100 * i}&limit=100"
    response["paging"].key?("next") ? (topic_content << response = get_response(url)) : (return topic_content)
  end
end

def get_unique_users(contents)
  unique_users = []
  contents.map do |content|
    content["data"]["posts"].map do |post|
      unique_users << post["created_by"]["name"]
    end
  end
end

def get_users(anime)
  Async do
    topic_contents = anime.map { |topic| Async { get_topic_content(topic[0]) } }.map(&:wait)

    user_names = topic_contents.map { |topic| Async { get_unique_users(topic).flatten } }.map(&:wait)

    anime.map.with_index { |topic, idx| Async { user_names[idx] << topic[1] } }.map(&:wait)
  end
end

def get_ids_and_lp(html)
  topic_id = []
  last_poster = []

  (1..).each do |i|
    break if (topic_row = html.at_css("tr#topicRow#{i}")).nil?

    topic_id << topic_row["data-topic-id"]
    last_poster << html.css("tr#topicRow#{i} td.forum_boardrow1").text.strip.match(/by\s+(.+)/i).to_s.split[1]
  end
  topic_id.zip(last_poster)
end

# rubocop:disable Metrics/MethodLength
def anime_data
  anime_data = []
  Async do
    anime_data = IDS.map { |id| Async { get_data(id) } }.map(&:wait)
    users = IDS.map { |id| Async { get_ids_and_lp(scrape_threads(id)) } }.map(&:wait)
    users.map! { |id| Async { get_users(id).wait } }.map!(&:wait)

    users.map.with_index do |arr, idx|
      Async do
        anime_data[idx]["unique_posters"] = arr.map do |names|
          Async { names.flatten.uniq.length }
        end.map.sum(&:wait)
      end
    end.map(&:wait)
  end
  anime_data
end
# rubocop:enable Metrics/MethodLength

headers = %w[Title Score Watching Dropped Favorites Planning UniqP]

workbook = RubyXL::Workbook.new
sheet = workbook.first

headers.each_with_index do |e, idx|
  sheet.add_cell(0, idx, e)
end

anime_data.each.with_index(1) do |e, idx|
  sheet.add_cell(idx, 0, e["title"])
  sheet.add_cell(idx, 1, e["mean"])
  sheet.add_cell(idx, 2, e["statistics"]["status"]["watching"].to_i)
  sheet.add_cell(idx, 3, e["statistics"]["status"]["dropped"].to_i)
  sheet.add_cell(idx, 4, e["num_favorites"])
  sheet.add_cell(idx, 5, e["statistics"]["status"]["plan_to_watch"].to_i)
  sheet.add_cell(idx, 6, e["unique_posters"])
end

timestamp = Time.new
timestamp.strftime("%Y-%m-%d %H:%M:%S")
workbook.write("FAL #{timestamp}.xlsx")
