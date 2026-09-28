pipeline {
    agent any

    environment {
        REPORTS_DIR = 'security-reports'
        SONAR_HOST_URL = 'http://sonarqube:9000'
        PATH = "/opt/sonar-scanner/bin:${env.PATH}"
        SONAR_TOKEN = 'squ_a76c5e818a392cb07370af0fb874c9e3fe84ec90'
        SONAR_PROJECT_KEY = 'VulnerableApp'
        SEMGREP_FAILED = 'false'
        SONAR_FAILED = 'false'
    }

    stages {
        stage('Install Dependencies') {
            steps {
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y python3 python3-pip python3-venv curl unzip docker.io default-jdk

                    if [ ! -d "/usr/lib/jvm/java-17-temurin" ]; then
                        sudo mkdir -p /usr/lib/jvm/java-17-temurin
                        curl -sL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" | sudo tar -xz -C /usr/lib/jvm/java-17-temurin --strip-components=1
                    fi

                    sudo pip3 install semgrep --break-system-packages || sudo pip3 install semgrep

                    SONAR_SCANNER_VERSION=8.1.0.6389
                    if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
                        sudo mkdir -p /opt/sonar-scanner
                        curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
                        sudo unzip -q /tmp/sonar-scanner.zip -d /tmp/sonar-scanner-install
                        sudo cp -r /tmp/sonar-scanner-install/sonar-scanner-*/. /opt/sonar-scanner/
                        sudo chmod -R +x /opt/sonar-scanner/bin /opt/sonar-scanner/jre/bin
                        rm -rf /tmp/sonar-scanner.zip /tmp/sonar-scanner-install
                    fi
                '''
            }
        }

        stage('Build (Compile Java)') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew classes printRuntimeClasspath --no-daemon'
            }
        }

        stage('Security Analysis') {
            steps {
                script {
                    sh 'mkdir -p $REPORTS_DIR'
                    
                    def semgrepExitCode = 0

                    parallel (
                        'Semgrep SAST': {
                            sh 'chmod +x scripts/semgrep-scan.sh'
                            semgrepExitCode = sh(
                                script: './scripts/semgrep-scan.sh . $REPORTS_DIR', 
                                returnStatus: true
                            )
                        },
                        'SonarQube Analysis': {
                            sh 'chmod +x scripts/sonarqube-scan.sh'
                            withSonarQubeEnv('sonar') { 
                                sh './scripts/sonarqube-scan.sh . $SONAR_PROJECT_KEY $SONAR_HOST_URL $SONAR_TOKEN $REPORTS_DIR'
                            }
                        }
                    )

                    if (semgrepExitCode != 0) {
                        env.SEMGREP_FAILED = 'true'
                        echo "Semgrep found blocking vulnerabilities."
                    }

                    timeout(time: 10, unit: 'MINUTES') {
                        def qg = waitForQualityGate(abortPipeline: false)
                        if (qg.status != 'OK') {
                            env.SONAR_FAILED = 'true'
                            echo "SonarQube Quality Gate failed with status: ${qg.status}."
                        } else {
                            echo "SonarQube Quality Gate passed successfully."
                        }
                    }
                }
            }
        }

        stage('Deduplicate Findings') {
            steps {
                sh 'python3 scripts/security_processor.py --workspace $REPORTS_DIR'
            }
        }

        stage('Quality Gate Enforcement') {
            steps {
                script {
                    def hasFailed = false
                    
                    if (env.SEMGREP_FAILED == 'true') {
                        hasFailed = true
                    }
                    
                    if (env.SONAR_FAILED == 'true') {
                        hasFailed = true
                    }

                    if (hasFailed) {
                        currentBuild.result = 'FAILURE'
                        error("Pipeline failed due to security vulnerabilities or Quality Gate violations.")
                    }
                }
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed.'
            // Scoped down specifically to your requested processor outputs and raw scan outputs
            archiveArtifacts artifacts: "${env.REPORTS_DIR}/sonar_raw.json, ${env.REPORTS_DIR}/semgrep_raw_output.json, ${env.REPORTS_DIR}/triage_batches.json, ${env.REPORTS_DIR}/normalized_findings.json", allowEmptyArchive: true
        }
    }
}
