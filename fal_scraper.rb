# frozen_string_literal: true

require "async"
require "net/http"
require "json"
require "rubyXL"
require "rubyXL/convenience_methods/workbook"

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

def get_data(id)
  url = "https://api.myanimelist.net/v2/anime/#{id}?fields=title,mean,num_favorites,statistics"
  get_response(url)
end

def get_topics(title)
  url = "https://api.myanimelist.net/v2/forum/topics?q=\"#{title} Episode Discussion\"&subboard_id=1&limit=100"
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

def clean_topics(title, topics)
  topics.filter_map do |topic|
    topic if topic["title"].include?("#{title} Episode")
  end
end

# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/AbcSize
def get_users(anime)
  Async do
    topic_contents = anime.map { |topic| Async { get_topic_content(topic["id"]) } }.map(&:wait)

    user_names = topic_contents.map { |topic| Async { get_unique_users(topic).flatten } }.map(&:wait)

    anime.map.with_index { |topic, idx| Async { user_names[idx] << topic["last_post_created_by"]["name"] } }.map(&:wait)
  end
end

# rubocop:disable Metrics/PerceivedComplexity
# rubocop:disable Metrics/CyclomaticComplexity
def anime_data
  anime_data = []
  Async do
    anime_data = IDS.map { |id| Async { get_data(id) } }.map(&:wait)
    topic_per_anime = anime_data.map { |data| Async { get_topics(data["title"]) } }.map(&:wait)

    cleaned_topics = topic_per_anime.map.with_index do |topic, idx|
      Async { clean_topics(anime_data[idx]["title"], topic["data"]) }
    end.map(&:wait)

    users = cleaned_topics.map { |id| Async { get_users(id).wait } }.map(&:wait)

    users.map.with_index do |f, idx|
      Async do
        anime_data[idx]["unique_posters"] = f.map do |q|
          Async { q.flatten.uniq.length }
        end.map.sum(&:wait)
      end
    end.map(&:wait)
  end
  anime_data
end
# rubocop:enable Metrics/PerceivedComplexity
# rubocop:enable Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/AbcSize

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
